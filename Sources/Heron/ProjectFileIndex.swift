import Foundation

/// A flat list of a project's files, for `@`-mention completion in Think.
///
/// Deliberately its own small index rather than borrowing Make's: Make's belongs to whichever
/// project *that* window has open and is rebuilt on its own schedule, while Think needs the
/// current track's working directory — which is a worktree, and often a different directory
/// entirely. Sharing would couple two stages' lifecycles for a list that costs milliseconds.
public final class ProjectFileIndex {
    /// Same ceiling the project indexer uses. A monorepo shouldn't turn a completion list into a
    /// memory problem, and nobody scrolls past the first few matches anyway.
    private static let maxFiles = 25_000

    /// Directories never worth offering: generated, vendored, or enormous. Matches what the file
    /// explorer already hides, so completion and the tree agree about what "the project" is.
    private static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "build", "dist", ".next",
        "Pods", ".venv", "venv", "__pycache__", ".swiftpm", ".gradle", "target",
    ]

    public private(set) var relativePaths: [String] = []
    private var indexedRoot: URL?
    private var isStale = false

    /// The project changed under us (a watcher said so); the next `refresh` rescans even for the
    /// same root. Before this the index was frozen at first attach, so a file the agent had just
    /// created couldn't be `@`-mentioned for the life of the track (audit H8).
    public func markStale() { isStale = true }

    /// Rebuilds off the main thread when the root changes; a repeat call for the same root is
    /// free, so callers can invoke this on every attach without thinking about it.
    public func refresh(root: URL, completion: @escaping () -> Void) {
        guard indexedRoot != root || isStale else { return completion() }
        indexedRoot = root
        isStale = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paths = Self.scan(root: root)
            DispatchQueue.main.async {
                guard let self, self.indexedRoot == root else { return }
                self.relativePaths = paths
                completion()
            }
        }
    }

    /// Best matches for a partial path, ranked by the same fuzzy scorer Quick Open uses so
    /// `@thvc` finds `ThinkWorkspaceViewController.swift` here too.
    ///
    /// An *empty* query (a bare `@`) is answered with the shallowest paths, alphabetically —
    /// enumeration order is an implementation detail of the filesystem walk and would look
    /// random. Shallow-first puts a project's top-level files where someone typing `@` with
    /// nothing in mind is most likely to be heading.
    public func matches(for query: String, limit: Int = 12) -> [String] {
        guard !query.isEmpty else {
            return relativePaths
                .sorted { left, right in
                    let leftDepth = left.filter { $0 == "/" }.count
                    let rightDepth = right.filter { $0 == "/" }.count
                    if leftDepth != rightDepth { return leftDepth < rightDepth }
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                .prefix(limit)
                .map { $0 }
        }
        return relativePaths
            .compactMap { path in FuzzyMatcher.score(query: query, candidate: path).map { (path, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func scan(root: URL) -> [String] {
        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
            if paths.count >= maxFiles { break }
        }
        return paths
    }

    public init() {}
}
