import Foundation
import CryptoKit

/// Resolves the handful of filesystem facts Phase C's worktrees depend on. The load-bearing
/// detail behind all of it: inside a linked worktree, `.git` is a *file* containing `gitdir: …`,
/// not a directory, so a naive `projectRoot.appendingPathComponent(".git/side")` would fragment
/// per-track state depending on which worktree happened to open the project — a track's own
/// worktree would see an *empty* ledger the first time anything read `tracks.json` from inside
/// it. Every path here is resolved through git itself rather than assumed from string shape.
public enum GitPaths {
    /// The one directory every worktree of a repository agrees on — resolved via
    /// `--git-common-dir`, not `--git-dir` (which returns the *calling* worktree's own private
    /// git dir, a subdirectory of the common one). `nil` for a plain folder that isn't a git
    /// repo at all, or before the first commit in some edge cases `rev-parse` can't resolve.
    public static func commonGitDir(for projectRoot: URL) -> URL? {
        let result = runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: projectRoot.path)
        guard result.success, !result.output.isEmpty else { return nil }
        return URL(fileURLWithPath: result.output).standardizedFileURL
    }

    /// Where `TrackStore`/`AgentSessionStore` persist — `<common-git-dir>/side`. Opening the
    /// main checkout or any of its linked worktrees resolves to the exact same directory, which
    /// is what lets two windows on the same repo (one via the root, one via a worktree) share
    /// one ledger instead of each seeing a different, fragmented one.
    public static func stateDirectory(for projectRoot: URL) -> URL? {
        commonGitDir(for: projectRoot)?.appendingPathComponent("side")
    }

    /// A stable identity for this repository, independent of which worktree (if any) was used
    /// to open it — the common git dir's own resolved path. Two separate clones of the same
    /// repo still get different identities (genuinely different `.git` directories on disk),
    /// which is correct: they really are two independent working copies, not "the same project."
    public static func projectIdentity(for projectRoot: URL) -> String? {
        // The cached launch probe already answered this, so asking git again costs a whole
        // process — ~27ms on a machine where a bare spawn is ~72ms, and it was the single
        // largest remaining item in the launch profile. `ProjectContextRegistry` calls this on
        // every project open purely to build its dictionary key.
        if let cached = GitLaunchProbe.cached(projectRoot: projectRoot)?.commonGitDir {
            return URL(fileURLWithPath: cached).resolvingSymlinksInPath().path
        }
        return commonGitDir(for: projectRoot)?.resolvingSymlinksInPath().path
    }

    /// Where a track's linked worktree lives on disk — deliberately outside the repo entirely.
    /// `ProjectFileAccess.scan` only excludes a fixed list (`.git`, `node_modules`, `.build`,
    /// etc.), not arbitrary in-repo directories, so an in-repo location would silently multiply
    /// quick-open, search, and the file explorer by however many tracks exist. Keyed by a hash
    /// of the *common git dir* (not the project's display name), so a track's worktree location
    /// survives the user renaming or moving the repo folder.
    public static func worktreesRootDirectory(for projectRoot: URL) -> URL? {
        guard let identity = projectIdentity(for: projectRoot) else { return nil }
        return worktreesSupportDirectory.appendingPathComponent("Side/Worktrees/\(projectRoot.lastPathComponent)-\(stableHash(identity))")
    }

    /// Where worktrees go: Application Support, except under tests. Test runs (XCTest, and the
    /// app launched for UI testing, which sets this) create tracks by the hundred, and they used
    /// to leave a folder each in the person's own Application Support.
    public nonisolated(unsafe) static var worktreesSupportDirectory: URL = {
        if UsageStore.isTesting { return FileManager.default.temporaryDirectory.appendingPathComponent("SideTests", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }()

    public static func worktreePath(forBranchSlug slug: String, projectRoot: URL) -> URL? {
        worktreesRootDirectory(for: projectRoot)?.appendingPathComponent(slug)
    }

    /// Short, filesystem-safe, and — critically — stable across process launches. `Hasher` is
    /// deliberately *not* used here: Swift randomizes its seed per process for hash-flooding
    /// protection, which would relocate every track's worktree to a new path on every relaunch.
    private static func stableHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Git processes launched, and the main thread's time spent waiting on them: what the
    /// background-work budgets measure (SIDE_RFC_HERON_EFFICIENCY.md, D7). A git call on the main
    /// thread is a hitch that grows with the repository.
    public struct Metrics: Sendable {
        public var processes = 0
        public var mainThreadTime: TimeInterval = 0
        /// The last few commands run on the main thread, so a budget can name the offender.
        public var mainThreadCommands: [String] = []
    }
    private static let metricsLock = NSLock()
    nonisolated(unsafe) private static var counted = Metrics()
    public static var metrics: Metrics { metricsLock.withLock { counted } }

    /// Signalled when `process` exits; set before it runs. `waitUntilExit()` added about 65 ms
    /// to every git call, measured (it polls the run loop); a termination handler costs about 2.
    /// A checkpoint makes several calls, so that was most of its time (D7).
    static func exitSignal(_ process: Process) -> DispatchSemaphore {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        return exited
    }

    private static func measured<T>(_ args: [String], _ run: () -> T) -> T {
        let onMain = Thread.isMainThread
        let start = DispatchTime.now().uptimeNanoseconds
        let result = run()
        let spent = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        metricsLock.withLock {
            counted.processes += 1
            if onMain {
                counted.mainThreadTime += spent
                counted.mainThreadCommands = Array((counted.mainThreadCommands + [args.prefix(3).joined(separator: " ")]).suffix(20))
            }
        }
        return result
    }

    /// `extraEnvironment` exists for `GIT_INDEX_FILE` — the only safe way to stage a commit
    /// without touching whatever the user already has staged in the repository's real index
    /// (see `AgentRunner.createCheckpointIfNeeded`).
    @discardableResult
    public static func runGit(_ args: [String], cwd: String, extraEnvironment: [String: String] = [:]) -> (success: Bool, output: String) {
        measured(args) { launchGit(args, cwd: cwd, extraEnvironment: extraEnvironment) }
    }

    private static func launchGit(_ args: [String], cwd: String, extraEnvironment: [String: String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = SpawnEnvironment.current()
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = Self.exitSignal(process)
        do { try process.run() } catch { return (false, error.localizedDescription) }
        // Read *before* waiting. `waitUntilExit()` first is a deadlock: once git fills the
        // ~64KB pipe buffer it blocks writing, while we block waiting for it to exit, and
        // neither side ever moves. Reproduced against a 175KB blob — `git show` of any large
        // file, or a diff over ~64KB, hung the app until Force Quit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }

    /// Like `runGit`, but returns git's output **verbatim**.
    ///
    /// `runGit` trims whitespace, which is right for `rev-parse` and wrong — silently and
    /// destructively — for `status --porcelain`, whose first two columns *are* the status and
    /// whose first column is a space for a worktree-modified file. Trimming ate that space, so
    /// ` M src/mathUtils.ts` became `M src/mathUtils.ts` and the 3-character prefix drop then
    /// produced `rc/mathUtils.ts`: a path git had never heard of.
    ///
    /// Only the *first* entry was affected, which is why this hid for so long — checkpointing
    /// worked whenever the first dirty file happened to be staged or untracked, and failed
    /// whenever it was merely modified. Before checkpoint failures were reported honestly, that
    /// failure printed as "✓ Checkpoint (no file changes)".
    public static func runGitRaw(_ args: [String], cwd: String) -> (success: Bool, output: String) {
        measured(args) { launchGitRaw(args, cwd: cwd) }
    }

    private static func launchGitRaw(_ args: [String], cwd: String) -> (success: Bool, output: String) {
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr goes nowhere: merging it would corrupt a format parsed by position.
        process.standardError = FileHandle.nullDevice
        let exited = Self.exitSignal(process)
        do { try process.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Every path git considers dirty (staged, unstaged, or untracked) relative to `cwd`'s repo
    /// root — used to snapshot a worktree's state before/after a batch of agent actions, so a
    /// checkpoint can stage only what actually changed *during* the batch instead of everything
    /// sitting in the tree (which would misattribute a concurrent manual edit to the agent).
    ///
    /// Nil when git status failed. That is not a clean tree: read as one, it made a checkpoint
    /// claim every dirty file, promotion pass its cleanliness check, and delete-track remove a
    /// working copy with `--force` unasked (2026-09-30 audit, GIT-11).
    public static func dirtyPaths(cwd: String) -> Set<String>? {
        status(cwd: cwd)?.dirty
    }

    /// One `git status` read three ways: the dirty paths, the commit HEAD names (nil before the
    /// first commit), and whether anything is staged. A checkpoint needs all three, and asking
    /// in one process instead of two is part of what keeps it within budget (D7).
    public struct Status: Sendable {
        public var dirty: Set<String> = []
        /// Ignored files and directories, only when asked for (`includeIgnored`).
        public var ignored: Set<String> = []
        public var head: String?
        public var hasStaged = false
    }

    /// `includeIgnored` adds git's ignored entries (a directory is one entry): what
    /// `worktree remove --force` deletes besides the dirty files.
    public static func status(cwd: String, includeIgnored: Bool = false) -> Status? {
        // `-z` for two independent reasons, both of which silently broke checkpoints: git
        // *quotes* any path with non-ASCII or unusual bytes by default (`"caf\303\251.txt"`),
        // and those quotes were passed straight into `git add`, which then matched nothing —
        // so a single accented filename anywhere in the tree made every checkpoint commit
        // fail. `-z` also uses NUL separators, so a filename containing a newline can't split
        // one entry into two.
        // `runGitRaw`, not `runGit`: the format is read by position. See above.
        // `--no-optional-locks`: status otherwise rewrites the index to refresh stat data, which
        // contends with the user's own git and changes the file a checkpoint copies.
        // `--untracked-files=all`: by default a new directory is one entry (`newdir/`), so a
        // checkpoint staged the whole directory, the person's own new files in it included, a
        // baseline `gen/` hid the agent's new `gen/agent.txt`, and `status.showUntrackedFiles=no`
        // hid new files altogether (2026-09-30 audit, GIT-3). The flag overrides that setting.
        // `--ignored=matching` keeps an ignored directory one entry (`node_modules/`) under it.
        let result = runGitRaw(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"] + (includeIgnored ? ["--ignored=matching"] : []), cwd: cwd)
        guard result.success else { return nil }
        return parseStatus(result.output)
    }

    /// `git status --porcelain=v2 --branch -z`: headers (`# branch.oid <sha>`), then one entry
    /// per path: `1 XY …8 fields… path`, `2 XY …9 fields… path` followed by the source path
    /// as its own field (a rename), `u XY …10 fields… path`, `? path`, `! path`. X is the index
    /// against HEAD, so anything but `.` there is staged.
    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        // Walked by position: removing each entry from the front was quadratic in the number of
        // dirty files (a build's untracked output, say).
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true)
        var position = 0
        while position < entries.count {
            let entry = entries[position]
            position += 1
            func path(after fields: Int) -> String? {
                let parts = entry.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false)
                return parts.count == fields + 1 ? String(parts[fields]) : nil
            }
            switch entry.first {
            case "#":
                if entry.hasPrefix("# branch.oid "), !entry.hasSuffix("(initial)") { status.head = String(entry.dropFirst("# branch.oid ".count)) }
            case "1", "2", "u":
                let xy = entry.dropFirst(2).prefix(2)
                if xy.first != "." { status.hasStaged = true }
                let fields = entry.first == "1" ? 8 : (entry.first == "2" ? 9 : 10)
                if let path = path(after: fields) { status.dirty.insert(path) }
                // A rename's source path is the next field; it isn't dirty in its own right, and
                // staging it would name a path that no longer exists.
                if entry.first == "2" { position += 1 }
            case "?":
                status.dirty.insert(String(entry.dropFirst(2)))
            case "!":
                status.ignored.insert(String(entry.dropFirst(2)))
            default:
                continue
            }
        }
        return status
    }

    /// The worktree's own index file, when it can be found without asking git: `.git/index`,
    /// or for a linked worktree the `index` in the directory its `.git` file points at. Nil when
    /// the repository splits its index (`sharedindex.*` beside it), which a copy wouldn't carry.
    public static func indexFile(worktree root: String) -> URL? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        let gitDir: URL
        if isDirectory.boolValue {
            gitDir = dotGit
        } else {
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
            let path = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)
        }
        let index = gitDir.appendingPathComponent("index")
        let shared = (try? FileManager.default.contentsOfDirectory(atPath: gitDir.path))?.contains { $0.hasPrefix("sharedindex.") } ?? true
        guard !shared, FileManager.default.fileExists(atPath: index.path) else { return nil }
        return index
    }

    /// Puts `replacement` in place as the index, as git itself does (`index.lock`, created
    /// exclusively, then renamed over), and only if the index still holds `expected`: if anything
    /// else wrote it meanwhile, nothing is replaced and the caller asks git instead.
    public static func replaceIndex(_ index: URL, expected: Data, with replacement: Data) -> Bool {
        let lock = index.path + ".lock"
        let descriptor = open(lock, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        var written = false
        defer { if !written { unlink(lock) } }
        guard (try? Data(contentsOf: index)) == expected else { close(descriptor); return false }
        let wrote = replacement.withUnsafeBytes { buffer in write(descriptor, buffer.baseAddress, buffer.count) == buffer.count }
        close(descriptor)
        guard wrote, rename(lock, index.path) == 0 else { return false }
        written = true
        return true
    }
}
