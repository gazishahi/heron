import Foundation

public struct ScannedFile {
    public let url: URL
    public let relativePath: String

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}

/// Shared project-file walking and text decoding. Extracted from
/// MakeWorkspaceViewController (which still owns the quick-open index built on top of it) so
/// Heron's read tools see exactly the same files, with the same ignore rules, that quick-open
/// shows the user — an agent that could "see" files the file explorer hides, or vice versa,
/// would be confusing in both directions.
public enum ProjectFileAccess {
    public static let maxIndexedFiles = 25000
    public static let maxReadableFileSize = 10_000_000

    public static let ignoredDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".next", "Pods", "dist", "build",
        ".venv", "venv", "vendor", "Carthage", "target", "out", ".cache", "coverage",
        "__pycache__", ".tox", ".mypy_cache", ".pytest_cache",
    ]

    /// The project's files, from the last walk when it still holds (SIDE_RFC_HERON_EFFICIENCY.md,
    /// D7): `list_files` and `search_files` walked the whole tree on every call, 400 ms in a
    /// 20,000-file project. A directory's modification time changes whenever an entry in it is
    /// added, removed or renamed, and the list is names only, so the walk still holds while every
    /// directory it went through has the time it had. Checking that is a stat per directory.
    ///
    /// The last `cachedRoots` roots are kept (about 15 MB for 20,000 files each), the oldest let
    /// go: every worktree used to stay for the session, deleted tracks' too (2026-09-30 audit,
    /// CON-6). A walk cut short at `maxIndexedFiles` is kept as well: it's what a new walk would
    /// return while its directories hold, and a large project used to walk again on every call.
    public nonisolated static func scan(root: URL) -> [ScannedFile] {
        let key = root.standardizedFileURL.path
        if let cached = scanCacheLock.withLock({ scanCache[key] }), cached.directories.allSatisfy({ modificationTime($0.path) == $0.time }) {
            scanCacheLock.withLock { touch(key) }
            return cached.files
        }
        var directories: [(path: String, time: Int)] = []
        let files = walk(root: root, directories: &directories)
        scanCacheLock.withLock {
            scanCache[key] = (files, directories)
            touch(key)
            while scanOrder.count > cachedRoots { scanCache[scanOrder.removeFirst()] = nil }
        }
        return files
    }

    /// A root that's gone (a track's folder removed): its walk is let go now.
    public nonisolated static func forget(root: URL) {
        let key = root.standardizedFileURL.path
        scanCacheLock.withLock {
            scanCache[key] = nil
            scanOrder.removeAll { $0 == key }
        }
    }

    public static let cachedRoots = 3

    /// Under the lock: `key` is the most recent.
    private static func touch(_ key: String) {
        scanOrder.removeAll { $0 == key }
        scanOrder.append(key)
    }

    /// How many roots are cached, for tests.
    static var cachedRootCount: Int { scanCacheLock.withLock { scanCache.count } }

    private static let scanCacheLock = NSLock()
    nonisolated(unsafe) private static var scanCache: [String: (files: [ScannedFile], directories: [(path: String, time: Int)])] = [:]
    nonisolated(unsafe) private static var scanOrder: [String] = []

    /// Nanoseconds.
    private static func modificationTime(_ path: String) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
    }

    private nonisolated static func walk(root: URL, directories: inout [(path: String, time: Int)]) -> [ScannedFile] {
        if let time = modificationTime(root.path) { directories.append((root.path, time)) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        // Every spelling the enumerator might use for the root. It hands back *resolved* paths
        // when the root sits behind a symlink — /var/… is /private/var/… on macOS — and the old
        // `replacingOccurrences(of: root.path + "/")` then found nothing to replace and reported
        // the absolute path as the relative one: "/privatesrc/a.swift". Caught by the first test
        // that ran a search under a temporary directory; a project cloned into a symlinked
        // folder would have shown the same garbage in every tool result and @-mention.
        let rootPrefixes = Set([root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]).map { $0 + "/" }
        func relativePath(of url: URL) -> String {
            let path = url.path
            if let prefix = rootPrefixes.first(where: { path.hasPrefix($0) }) { return String(path.dropFirst(prefix.count)) }
            let resolved = url.resolvingSymlinksInPath().path
            if let prefix = rootPrefixes.first(where: { resolved.hasPrefix($0) }) { return String(resolved.dropFirst(prefix.count)) }
            return url.lastPathComponent
        }
        var scanned: [ScannedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true && ignoredDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true, let time = modificationTime(url.path) { directories.append((url.path, time)) }
            if values?.isRegularFile == true && !url.pathExtension.isEmpty {
                scanned.append(ScannedFile(url: url, relativePath: relativePath(of: url)))
            }
            if scanned.count >= maxIndexedFiles { break }
        }
        return scanned.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Text, or nil for anything that isn't — see `TextFileCodec`. Binary is refused rather than
    /// decoded as Latin-1 mojibake, so the "not a text file" paths downstream are reachable.
    public static func decodeText(from data: Data) -> String? {
        TextFileCodec.decode(data)?.text
    }

    /// Resolves an agent-supplied path (relative to the project root, or absolute) and refuses
    /// anything that escapes the project. Load-bearing for the read tools: without it, a
    /// `../../.ssh/id_rsa` argument would happily be read and streamed back to a model.
    public static func resolveInsideProject(path: String, root: URL) -> URL? {
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let resolved = URL(fileURLWithPath: candidate.path).standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return resolved
    }

    /// Paths inside the project that tools must not *read*.
    ///
    /// `.git/side/` holds Side's own state: every track's record and every track's full
    /// conversation, including the user's own messages, which are never redacted (only tool
    /// results pass through the redactor). `.git` is already hidden from listings, but
    /// `read_file` takes an explicit path — so without this, an agent in one track could read
    /// everything the user has ever typed in every other track of the project, and prompt
    /// injection from a repo file made that reachable without the user's involvement.
    public static func isReadable(_ url: URL, root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(resolvedRoot + "/") else { return true }
        let components = pathComponents(of: url, below: resolvedRoot)
        // Case-folded: see `isWritable`.
        if components.count >= 2, components[0] == ".git", components[1] == "side" { return false }
        return components.first != ".side"
    }

    /// Path components below `root`, each lowercased.
    ///
    /// Lowercased because the default macOS filesystem is case-insensitive: `.GIT/hooks/x` and
    /// `.git/hooks/x` are the same file on APFS, and an exact-string guard let the first one
    /// through. The 2026-09-01 audit verified that as a write into the real hooks directory —
    /// code execution on the next unattended `git status`, no click required under Full autonomy.
    /// Folding on a case-sensitive volume refuses a few paths it could have allowed (`.Git/` as a
    /// user's own directory), which is the right side to err on for a guard whose failure mode is
    /// arbitrary code execution.
    private static func pathComponents(of url: URL, below resolvedRoot: String) -> [String] {
        let relative = String(url.path.dropFirst(resolvedRoot.count + 1))
        return relative.split(separator: "/").map { $0.lowercased() }
    }

    /// Paths that are inside the project but must never be *written* by a tool.
    ///
    /// Containment alone isn't enough for writes: `.git/config` and `.git/hooks/` turn an edit
    /// into code execution. A `core.fsmonitor` or `core.hooksPath` entry runs on git's next
    /// invocation — and Side itself runs `git status` unattended while checkpointing — so a
    /// write there escapes the approval boundary entirely, without ever going near
    /// `CommandAutoRunPolicy`. At `.full` autonomy it wouldn't even need a click.
    ///
    /// `.side/` is Side's own per-project state (track records, conversations); an agent
    /// rewriting it could forge checkpoints or plant standing instructions for future sessions.
    public static func isWritable(_ url: URL, root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(resolvedRoot + "/") else { return url.path != resolvedRoot }
        let first = pathComponents(of: url, below: resolvedRoot).first
        return first != ".git" && first != ".side"
    }
}
