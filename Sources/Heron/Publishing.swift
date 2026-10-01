import Foundation

/// Review's publishing half (the Integration work: constitution change model
/// `… → review → pull request (optional) → main`): push a track's branch, open a pull request,
/// and see whether the base moved on the remote.
///
/// Every action here is a person's: pushing and opening a pull request publish work, so Side only
/// does them from an explicit click with a confirmation that says what goes where. Agents can't
/// reach any of this; `git push` never auto-runs (`CommandAutoRunPolicy`).
public enum Publishing {
    public struct Remote: Equatable, Sendable {
        public let name: String
        public let url: String
        public var web: WebHost? { Publishing.webHost(for: url) }
    }

    /// Where a pull request (or merge request) is opened, parsed from the remote URL.
    public enum WebHost: Equatable, Sendable {
        case github(owner: String, repo: String)
        case gitlab(host: String, path: String)

        public var displayName: String {
            switch self {
            case .github(let owner, let repo): return "github.com/\(owner)/\(repo)"
            case .gitlab(let host, let path): return "\(host)/\(path)"
            }
        }
    }

    public struct State: Equatable, Sendable {
        public var remote: Remote?
        /// The branch exists on the remote (`<remote>/<branch>`).
        public var isOnRemote = false
        /// Commits on the branch the remote doesn't have yet, and the other way round.
        public var unpushed = 0
        public var remoteOnly = 0
        /// Commits on `<remote>/<base>` the local base doesn't have, as of the last fetch.
        public var baseBehindRemote = 0
        public var baseIsOnRemote = false
    }

    /// `origin` when there is one, else the first remote.
    public static func remote(cwd: String) -> Remote? {
        let list = GitPaths.runGit(["remote"], cwd: cwd)
        guard list.success else { return nil }
        let names = list.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = names.contains("origin") ? "origin" : names.first else { return nil }
        let url = GitPaths.runGit(["remote", "get-url", name], cwd: cwd)
        return url.success ? Remote(name: name, url: url.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    /// GitHub and GitLab, over https or ssh (`git@github.com:owner/repo.git`,
    /// `https://github.com/owner/repo`, `ssh://git@gitlab.example.com/group/sub/repo.git`).
    public static func webHost(for url: String) -> WebHost? {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://", "ssh://", "git://"] where rest.hasPrefix(scheme) { rest.removeFirst(scheme.count) }
        if let at = rest.firstIndex(of: "@"), rest[..<at].allSatisfy({ $0 != "/" }) { rest = String(rest[rest.index(after: at)...]) }
        // scp-like host:path, or host/path; a port after the host is dropped.
        guard let separator = rest.firstIndex(where: { $0 == ":" || $0 == "/" }) else { return nil }
        let host = String(rest[..<separator]).lowercased()
        var path = String(rest[rest.index(after: separator)...])
        if let slash = path.firstIndex(of: "/"), path[..<slash].allSatisfy(\.isNumber) { path = String(path[path.index(after: slash)...]) }
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        if host == "github.com" || host == "www.github.com" { return .github(owner: parts[0], repo: parts[1]) }
        if host.contains("gitlab") { return .gitlab(host: host, path: path) }
        return nil
    }

    /// What's pushed and what isn't, from the remote-tracking refs as of the last fetch (no
    /// network).
    public static func state(branch: String, baseRef: String, cwd: String) -> State {
        var state = State()
        guard let remote = remote(cwd: cwd) else { return state }
        state.remote = remote
        let remoteBranch = "refs/remotes/\(remote.name)/\(branch)"
        state.isOnRemote = GitPaths.runGit(["rev-parse", "--verify", "--quiet", remoteBranch], cwd: cwd).success
        if state.isOnRemote, let counts = leftRight(remoteBranch, "refs/heads/\(branch)", cwd: cwd) {
            (state.remoteOnly, state.unpushed) = counts
        } else {
            state.unpushed = count("refs/heads/\(branch)", notIn: "refs/remotes/\(remote.name)/\(baseRef)", cwd: cwd)
        }
        let remoteBase = "refs/remotes/\(remote.name)/\(baseRef)"
        state.baseIsOnRemote = GitPaths.runGit(["rev-parse", "--verify", "--quiet", remoteBase], cwd: cwd).success
        if state.baseIsOnRemote { state.baseBehindRemote = count(remoteBase, notIn: "refs/heads/\(baseRef)", cwd: cwd) }
        return state
    }

    private static func leftRight(_ left: String, _ right: String, cwd: String) -> (Int, Int)? {
        let result = GitPaths.runGit(["rev-list", "--left-right", "--count", "\(left)...\(right)"], cwd: cwd)
        let parts = result.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return result.success && parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Commits reachable from `ref` and not from `other` (all of `ref`'s when `other` is missing).
    private static func count(_ ref: String, notIn other: String, cwd: String) -> Int {
        let hasOther = GitPaths.runGit(["rev-parse", "--verify", "--quiet", other], cwd: cwd).success
        let result = GitPaths.runGit(["rev-list", "--count", ref] + (hasOther ? ["^\(other)"] : []), cwd: cwd)
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Git must never wait on a password prompt nobody can see: it fails instead, and the
    /// failure says to sign in.
    private static let noPrompt = ["GIT_TERMINAL_PROMPT": "0"]

    public static func fetch(remote: String, cwd: String) -> (succeeded: Bool, message: String) {
        let result = GitPaths.runGit(["fetch", "--quiet", remote], cwd: cwd, extraEnvironment: noPrompt)
        return (result.success, result.success ? "" : Self.explain(result.output, action: "check \(remote)"))
    }

    /// `git push -u <remote> <branch>`: never a force push.
    public static func push(branch: String, remote: String, cwd: String) -> (succeeded: Bool, message: String) {
        let result = GitPaths.runGit(["push", "--set-upstream", remote, "refs/heads/\(branch):refs/heads/\(branch)"], cwd: cwd, extraEnvironment: noPrompt)
        return (result.success, result.success ? "Pushed \(branch) to \(remote)." : Self.explain(result.output, action: "push \(branch)"))
    }

    private static func explain(_ output: String, action: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("terminal prompts disabled") || text.localizedCaseInsensitiveContains("could not read username")
            || text.localizedCaseInsensitiveContains("permission denied") || text.localizedCaseInsensitiveContains("authentication") {
            return "Couldn't \(action): git needs you to sign in to this remote. Push once from a terminal (Run) to store your credentials, then try again."
        }
        if text.contains("[rejected]") || text.localizedCaseInsensitiveContains("non-fast-forward") {
            return "Couldn't \(action): the remote has commits this branch doesn't. Pull them into the track first; Side never force-pushes."
        }
        return "Couldn't \(action): \(text.split(separator: "\n").last.map(String.init) ?? text)"
    }

    /// The page that opens a pull request with its title and body filled in.
    public static func newPullRequestURL(host: WebHost, base: String, branch: String, title: String, body: String) -> URL? {
        var components: URLComponents
        switch host {
        case .github(let owner, let repo):
            components = URLComponents(string: "https://github.com/\(owner)/\(repo)/compare/\(base)...\(branch)")!
            components.queryItems = [.init(name: "expand", value: "1"), .init(name: "title", value: title), .init(name: "body", value: body)]
        case .gitlab(let hostName, let path):
            components = URLComponents(string: "https://\(hostName)/\(path)/-/merge_requests/new")!
            components.queryItems = [
                .init(name: "merge_request[source_branch]", value: branch), .init(name: "merge_request[target_branch]", value: base),
                .init(name: "merge_request[title]", value: title), .init(name: "merge_request[description]", value: body),
            ]
        }
        // `+` in a query value would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// A pull request's body: what the track was for, each checkpoint, and what was verified.
    /// Written for a reviewer who wasn't in the conversation.
    public static func pullRequestBody(intent: String, checkpoints: [Checkpoint]) -> String {
        var lines: [String] = []
        if !intent.isEmpty { lines.append(intent); lines.append("") }
        let ordered = checkpoints.sorted { $0.createdAt < $1.createdAt }
        if !ordered.isEmpty {
            lines.append("Changes:")
            for checkpoint in ordered {
                let intentText = checkpoint.declaredIntent.isEmpty ? "Checkpoint" : checkpoint.declaredIntent
                let sha = checkpoint.gitCommitSHA.map { " (\($0.prefix(7)))" } ?? ""
                lines.append("- \(intentText)\(sha)")
            }
        }
        if let verified = ordered.last(where: { $0.verification != nil })?.verification {
            lines.append("")
            lines.append(verified.passed ? "Verified: \(verified.taskName) passed." : "Not passing: \(verified.taskName) failed (exit \(verified.exitCode.map(String.init) ?? "unknown")).")
        }
        return lines.joined(separator: "\n")
    }
}
