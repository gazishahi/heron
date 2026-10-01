import Foundation

/// Files the user saved by hand, and when — so a checkpoint doesn't commit a person's own save
/// as the agent's work.
///
/// A checkpoint stages what became dirty since its batch (or turn) began. Before this, a file the
/// user edited and saved in Make while a proposal card waited — or while an outside agent's turn
/// ran for minutes — became "newly dirty" too, and was committed under the agent's name; Undo of
/// that checkpoint then reverted the user's own edit (2026-09-01 audit, git F4;
/// `SIDE_RFC_BYO_HARNESS.md` step 3a). Make records every save here; checkpoints subtract the
/// saves made since they began. A path the agent is known to have changed stays the agent's even
/// if the user also saved it — the checkpoint says so.
///
/// Thread-safe: saves arrive on the main thread, checkpoints read from a background queue.
public final class UserSaveLog: @unchecked Sendable {
    public static let shared = UserSaveLog()

    private let lock = NSLock()
    private var saves: [(path: String, at: Date)] = []
    /// Enough for any one turn; older entries can't matter to a checkpoint still being written.
    private static let retention: TimeInterval = 24 * 60 * 60
    private static let capacity = 2_000

    public init() {}

    public func record(_ url: URL, at date: Date = Date()) {
        let path = Self.canonical(url.path)
        lock.withLock {
            saves.append((path, date))
            let cutoff = date.addingTimeInterval(-Self.retention)
            if saves.count > Self.capacity || (saves.first.map { $0.at < cutoff } ?? false) {
                saves.removeAll { $0.at < cutoff }
                if saves.count > Self.capacity { saves.removeFirst(saves.count - Self.capacity) }
            }
        }
    }

    /// Paths under `root` saved at or after `since`, relative to `root` — the same shape
    /// `GitPaths.dirtyPaths` reports, so the two subtract directly.
    public func paths(savedSince since: Date, under root: String) -> Set<String> {
        let base = Self.canonical(root)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return lock.withLock {
            Set(saves.filter { $0.at >= since && $0.path.hasPrefix(prefix) }.map { String($0.path.dropFirst(prefix.count)) })
        }
    }

    public func removeAll() { lock.withLock { saves.removeAll() } }

    /// `/tmp` and `/private/tmp` are one directory; so are the two spellings git and AppKit give.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
