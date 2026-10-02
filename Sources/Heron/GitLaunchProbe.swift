import Foundation

/// Everything about a project's git layout that Side needs before it can show anything — resolved
/// in **one** subprocess, and cached so a reopen needs none.
///
/// ## Why this exists
///
/// Opening a project used to run six separate `git` invocations on the main thread before the
/// first frame could be committed: `rev-parse --git-common-dir`, `rev-parse
/// --is-inside-work-tree`, `symbolic-ref HEAD`, `symbolic-ref refs/remotes/origin/HEAD`, and two
/// `show-ref` probes for main/master. Measured on a developer machine that is 520ms of frozen
/// window at every launch.
///
/// The measurement that mattered was of the *floor*: spawning `/bin/echo` — the cheapest process
/// that exists — cost **72.6ms**, while `git --version` cost 78ms. Git was contributing about six
/// milliseconds; the other seventy-two were the operating system's per-exec cost (on a machine
/// with endpoint security scanning, which is most machines this ships to). That inverts the
/// obvious optimization: making git do less work is pointless, and *spawning fewer processes* is
/// everything.
///
/// So: one spawn instead of six, and zero on a warm reopen.
///
/// ## Correctness of the cache
///
/// The cached facts are all slow-moving — where the repo's git directory is, whether the folder
/// is a repo at all, the default branch. But "slow-moving" is not "immutable": a user can switch
/// branches, `git init` a plain folder, or move a worktree between launches. So the cache is
/// **optimistic, never authoritative**: it is used to render immediately, a real probe runs off
/// the main thread regardless, and anything that disagrees is corrected. A stale cache costs one
/// frame of wrong branch name, never a wrong decision — every operation that acts on git state
/// (promote, checkpoint, switch) re-reads it at the time it acts.
public struct GitLaunchProbe: Codable, Equatable {
    /// Where this type persists. `.standard` in the app; tests point it at a private suite, because
    /// parallel test processes sharing one defaults domain lose each other's writes — the flake
    /// that showed up as an acknowledgement or a cache entry vanishing between two lines of a test.
    public nonisolated(unsafe) static var defaults: UserDefaults = HeronDefaults.store

    /// Absolute path of the common git directory — the same directory for a main checkout and
    /// all of its linked worktrees, which is what lets opening either resolve to one ledger.
    /// nil when the folder isn't a git repository.
    public var commonGitDir: String?
    public var isInsideWorkTree: Bool
    /// The branch HEAD points at, or nil in a detached HEAD.
    public var currentBranch: String?
    /// Best guess at the repository's trunk, by the same precedence the old chain used:
    /// origin/HEAD, then main, then master, then wherever HEAD points.
    public var defaultBranch: String

    public var isRepository: Bool { commonGitDir != nil && isInsideWorkTree }

    // MARK: - Probing

    /// One `git` process answering every question the launch path used to ask separately.
    ///
    /// `rev-parse` accepts several queries in one invocation and prints one line per query, in
    /// order — so the git-dir, work-tree, and HEAD questions cost one spawn between them. The
    /// default-branch probes can't join that call (`symbolic-ref` and `show-ref` are separate
    /// commands), so they're resolved from `git branch --list` output already in hand, and only
    /// fall back to a second spawn in the rare case that isn't enough.
    public static func probe(projectRoot: URL) -> GitLaunchProbe {
        let cwd = projectRoot.path
        // Parsed by *shape*, not by position, and without trusting the exit status. Two things
        // make the obvious version wrong, both found by running it against a real repository
        // with no commits yet:
        //
        //   - `rev-parse` exits 128 there even though it printed every value asked for, so a
        //     `guard success` threw away a perfectly good answer.
        //   - `runGit` merges stderr into stdout, so git's "fatal: ambiguous argument 'HEAD'"
        //     arrives *ahead* of the real output and shifts every positional read.
        //
        // Recognizing each line by what it looks like — a path, a boolean, a ref — is immune to
        // both, and to git someday reordering or adding output.
        let combined = GitPaths.runGit(
            ["rev-parse", "--path-format=absolute", "--git-common-dir", "--is-inside-work-tree", "--symbolic-full-name", "HEAD"],
            cwd: cwd
        )
        let lines = combined.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Standardized so it compares equal to what `GitPaths.commonGitDir` returns — on macOS a
        // temp path is /var/… via a symlink and /private/var/… once resolved: the same directory,
        // not the same string.
        let gitDir = lines.first { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let insideWorkTree = lines.contains("true")
        // A branch reads as `refs/heads/<name>`; a detached HEAD reads as the literal "HEAD".
        let head = lines.first { $0.hasPrefix("refs/heads/") }
            .map { String($0.dropFirst("refs/heads/".count)) }

        guard gitDir != nil, insideWorkTree else {
            return GitLaunchProbe(commonGitDir: nil, isInsideWorkTree: false, currentBranch: nil, defaultBranch: "")
        }
        var probe = GitLaunchProbe(
            commonGitDir: gitDir, isInsideWorkTree: insideWorkTree,
            currentBranch: head, defaultBranch: head ?? ""
        )
        if insideWorkTree { probe.defaultBranch = resolveDefaultBranch(cwd: cwd, head: head) }
        return probe
    }

    /// One spawn, listing the refs that decide the trunk, instead of three probes for them.
    private static func resolveDefaultBranch(cwd: String, head: String?) -> String {
        let refs = GitPaths.runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"],
            cwd: cwd
        )
        let names = Set(refs.output.split(separator: "\n").map(String.init))
        // origin/HEAD wins when present, but `for-each-ref` prints the symbolic ref's own name
        // rather than its target, so its target still needs one read — only in that case.
        if names.contains("refs/remotes/origin/HEAD") {
            let target = GitPaths.runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd: cwd)
            if target.success, let name = target.output.split(separator: "/").last { return String(name) }
        }
        if names.contains("refs/heads/main") { return "main" }
        if names.contains("refs/heads/master") { return "master" }
        if let head { return head }
        // A repository with no commits has no refs at all to read, and HEAD's symbolic name
        // reads as detached — but it does point at a branch that simply doesn't exist yet.
        // Worth one extra spawn, because it only happens in a brand-new repository.
        let symbolic = GitPaths.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd)
        return symbolic.success ? symbolic.output : ""
    }

    // MARK: - Cache

    private static let defaultsKey = "SideGitLaunchProbeCache"
    /// Cached project paths, least-recently-written first — the eviction order.
    private static let defaultsOrderKey = "SideGitLaunchProbeCacheOrder"
    /// Bounded — this is a launch accelerator, not a record worth keeping forever.
    private static let maxCachedProjects = 24

    public static func cached(projectRoot: URL) -> GitLaunchProbe? {
        guard let raw = defaults.dictionary(forKey: defaultsKey) as? [String: Data],
              let data = raw[projectRoot.standardizedFileURL.path] else { return nil }
        return try? JSONDecoder().decode(GitLaunchProbe.self, from: data)
    }

    public static func cache(_ probe: GitLaunchProbe, projectRoot: URL) {
        var raw = (defaults.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
        guard let data = try? JSONEncoder().encode(probe) else { return }
        let path = projectRoot.standardizedFileURL.path
        raw[path] = data

        // Evicted by recency, not by `keys.sorted()`.
        //
        // Alphabetical eviction dropped whichever project's path happened to sort lowest — which
        // can be the entry being written this very instant, so caching a project could silently
        // fail to cache it. It surfaced as a flaky test rather than a user report, because it
        // needs a full cache to bite, but the failure it produces in the app is a launch that
        // re-probes git every time for one unlucky project and nobody can see why.
        var order = (defaults.array(forKey: defaultsOrderKey) as? [String]) ?? []
        order.removeAll { $0 == path }
        order.append(path)
        // Anything in the dictionary the order list never saw (written by an older build) is
        // oldest by definition, so it goes at the front rather than being kept forever.
        let unordered = raw.keys.filter { !order.contains($0) }
        order = unordered.sorted() + order
        while order.count > maxCachedProjects, let oldest = order.first {
            order.removeFirst()
            raw.removeValue(forKey: oldest)
        }
        defaults.set(raw, forKey: defaultsKey)
        defaults.set(order, forKey: defaultsOrderKey)
    }

    public init(commonGitDir: String?, isInsideWorkTree: Bool, currentBranch: String?, defaultBranch: String) {
        self.commonGitDir = commonGitDir
        self.isInsideWorkTree = isInsideWorkTree
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
    }
}
