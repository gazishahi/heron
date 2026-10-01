import Foundation

/// A track's conversation on disk as an append-only log: one header line, then one line per turn.
///
/// The shape this replaces re-encoded and rewrote the *entire* session on every appended turn.
/// Measured on a 200-turn conversation with realistic tool results, that meant ~409MB pushed
/// through the disk to persist a 4MB conversation — 100× write amplification — with the cost of
/// each append growing linearly, so by late in a long conversation a single exchange spent tens
/// of milliseconds re-serializing history that hadn't changed. Appending one line is O(that
/// turn), forever.
///
/// Newline-delimited JSON rather than a database because the failure modes stay legible: the
/// file is readable, diffable, and a truncated final line (a crash mid-write) costs exactly the
/// turn that was being written instead of the conversation.
public enum SessionLog {
    /// Bumped independently of `JSONStore.currentVersion` — this is a different file format, not
    /// a different payload shape.
    public static let currentVersion = 1

    /// Everything about a session except its turns. Provider/model/lastActiveAt deliberately
    /// live in the store's index too, which is what lets an append avoid rewriting this line:
    /// the index is small, already written per turn, and authoritative for those three fields.
    private struct Header: Codable {
        public let logVersion: Int
        public let id: UUID
        public let trackKey: String
        public let providerId: String
        public let modelId: String
        public let createdAt: Date
        public let lastActiveAt: Date
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // No .prettyPrinted: every line is one record, and newlines inside a record would break
        // the format outright.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads a session back. A malformed line is skipped rather than failing the whole read:
    /// losing one turn is recoverable, losing the conversation is not — and the old all-or-
    /// nothing decode meant a single bad block discarded everything, after which the next
    /// append silently overwrote the file.
    public static func read(from url: URL) -> AgentSession? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        let decoder = decoder()
        guard let header = try? decoder.decode(Header.self, from: Data(lines.removeFirst())) else {
            PersistenceFailureReporter.shared.report(
                url: url, operation: .read,
                error: NSError(domain: "SessionLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreadable session header"])
            )
            return nil
        }
        var turns: [AgentTurn] = []
        turns.reserveCapacity(lines.count)
        var skipped = 0
        for line in lines {
            if let turn = try? decoder.decode(AgentTurn.self, from: Data(line)) {
                turns.append(turn)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            PersistenceFailureReporter.shared.report(
                url: url, operation: .read,
                error: NSError(domain: "SessionLog", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(skipped) unreadable turn\(skipped == 1 ? "" : "s") skipped; the rest of the conversation was recovered"
                ])
            )
        }
        return AgentSession(
            id: header.id, trackKey: header.trackKey, providerId: header.providerId,
            modelId: header.modelId, turns: turns, createdAt: header.createdAt,
            lastActiveAt: header.lastActiveAt
        )
    }

    /// Rewrites the whole file — session creation, and compaction, which replaces every turn.
    @discardableResult
    public static func write(_ session: AgentSession, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = encoder()
            let header = Header(
                logVersion: currentVersion, id: session.id, trackKey: session.trackKey,
                providerId: session.providerId, modelId: session.modelId,
                createdAt: session.createdAt, lastActiveAt: session.lastActiveAt
            )
            var data = try encoder.encode(header)
            data.append(UInt8(ascii: "\n"))
            for turn in session.turns {
                data.append(try encoder.encode(turn))
                data.append(UInt8(ascii: "\n"))
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .write, error: error)
            return false
        }
    }

    /// Appends one turn — the hot path, and the whole point of the format.
    ///
    /// Returns false when the file isn't there to append to, so the caller can fall back to a
    /// full write rather than silently dropping the turn.
    @discardableResult
    public static func append(_ turn: AgentTurn, to url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            var data = try encoder().encode(turn)
            data.append(UInt8(ascii: "\n"))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .write, error: error)
            return false
        }
    }
}
