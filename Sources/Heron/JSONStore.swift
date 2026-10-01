import Foundation

/// One shared, versioned, failure-reporting JSON file format for every persisted store.
///
/// Two problems this exists to fix. First, none of the stores recorded a schema version, so
/// there was no way to tell an old file from a new one and no place for a migration to hook —
/// adding a single non-optional field to `AgentSession` or `Checkpoint` would have made every
/// existing file fail to decode and silently read back as empty. Second, every write was a
/// `try? data.write(...)`: a full disk, a revoked permission, or a read-only volume lost the
/// user's tracks and conversations without a word.
///
/// Files are written as `{"schemaVersion": N, "payload": …}`. A bare payload (no envelope) is
/// read as version 1 — that's every file written before this existed, so no migration pass is
/// needed to adopt it; the next write upgrades the file in place.
public enum JSONStore {
    /// Bump when a change can't be expressed as "a new field with a default." Tolerant decoding
    /// (`decodeIfPresent` with a default, which every persisted struct here now uses) covers
    /// additive changes without a version bump; this is for renames, splits, and semantic
    /// changes, where `read`'s reported version tells the caller what shape it's holding.
    public static let currentVersion = 2

    private struct Envelope<Payload: Codable>: Codable {
        public let schemaVersion: Int
        public let payload: Payload
    }

    private static func encoder(compact: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns `nil` when the file doesn't exist yet (the ordinary first-run case) and reports a
    /// failure when it exists but can't be read or decoded — a corrupt file that silently reads
    /// as "no data" is how a user loses work without knowing it happened.
    public static func read<Payload: Codable>(_ type: Payload.Type, from url: URL) -> (payload: Payload, version: Int)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .read, error: error)
            return nil
        }
        let decoder = decoder()
        if let envelope = try? decoder.decode(Envelope<Payload>.self, from: data) {
            return (envelope.payload, envelope.schemaVersion)
        }
        do {
            // Pre-envelope file: the payload sat at the top level. Version 1 by definition.
            return (try decoder.decode(Payload.self, from: data), 1)
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .read, error: error)
            quarantine(url)
            return nil
        }
    }

    /// Moves a file that exists but cannot be decoded out of the way before anyone can write over it.
    ///
    /// Reporting the corruption was never the whole job. Every loader substitutes an empty
    /// collection for a failed read, and the first ordinary save afterwards — a reconcile can
    /// trigger one seconds after launch — wrote that empty collection over the corrupt file. One
    /// alert, then the evidence was gone for good, along with any chance of recovering the tracks
    /// or conversations it held. Found by the 2026-09-01 audit, escalated from the 2026-08-30
    /// "no backups on corruption": it was not merely unbacked-up, it was actively destroyed.
    ///
    /// The quarantined copy sits beside the original with a timestamp, so a user (or a future
    /// repair tool) can still read it. A failure to move it is reported and the read still fails —
    /// but in that case the original stays, which is still better than the old behaviour.
    public static func quarantinePath(for url: URL, at date: Date = Date()) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return url.appendingPathExtension("corrupt-\(stamp)")
    }

    private static func quarantine(_ url: URL) {
        let destination = quarantinePath(for: url)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            NSLog("[Side] quarantined unreadable %@ to %@", url.lastPathComponent, destination.lastPathComponent)
        } catch {
            PersistenceFailureReporter.shared.report(url: destination, operation: .write, error: error)
        }
    }

    /// Atomic, and loud on failure. Returns whether the write landed, for callers that need to
    /// avoid treating unsaved state as saved.
    @discardableResult
    /// `compact` for a file only Side reads and rewrites often (an index, a ledger): no
    /// indentation to write and parse each time.
    public static func write<Payload: Codable>(_ payload: Payload, to url: URL, compact: Bool = false) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder(compact: compact).encode(Envelope(schemaVersion: currentVersion, payload: payload))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            PersistenceFailureReporter.shared.report(url: url, operation: .write, error: error)
            return false
        }
    }
}

extension JSONStore {
    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pending: [URL: () -> Void] = [:]

    /// Writes `payload()` to `url` a moment from now, once however many times it's asked for
    /// meanwhile (SIDE_RFC_HERON_EFFICIENCY.md, D7: the session index was rewritten on every
    /// turn, and usage on every request). The payload is read when it's written, so the latest
    /// state goes. `flushPendingWrites` writes everything waiting, at quit.
    public static func writeSoon<Payload: Codable>(to url: URL, delay: TimeInterval = 1, compact: Bool = true, _ payload: @escaping () -> Payload) {
        let isFirst = pendingLock.withLock {
            let first = pending[url] == nil
            pending[url] = { write(payload(), to: url, compact: compact) }
            return first
        }
        guard isFirst else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { flush(url) }
    }

    public static func flushPendingWrites() {
        let writes = pendingLock.withLock { () -> [() -> Void] in
            defer { pending = [:] }
            return Array(pending.values)
        }
        for write in writes { write() }
    }

    private static func flush(_ url: URL) {
        let write = pendingLock.withLock { pending.removeValue(forKey: url) }
        write?()
    }
}

/// Where persistence failures go instead of into a `try?`.
///
/// Deliberately deduplicated per file and operation: a store that saves on every keystroke would
/// otherwise produce an unbounded stack of identical alerts the moment a disk fills up. The first
/// failure for a given file is surfaced; later identical ones are counted, not repeated.
public final class PersistenceFailureReporter: @unchecked Sendable {
    public static let shared = PersistenceFailureReporter()

    public enum Operation: String, Sendable {
        case read
        case write
    }

    /// Unchecked for `error` only: built once, read-only, handed to the main thread to present.
    public struct Failure: @unchecked Sendable {
        public let url: URL
        public let operation: Operation
        public let error: Error
        /// How many times this same file/operation has failed, including this one.
        public let occurrenceCount: Int

        public init(url: URL, operation: Operation, error: Error, occurrenceCount: Int) {
            self.url = url
            self.operation = operation
            self.error = error
            self.occurrenceCount = occurrenceCount
        }
    }

    /// Posted on the main thread for whoever presents failures (`AppDelegate`). A notification
    /// rather than a direct call because persistence lives below the UI layer and shouldn't
    /// reach up into it.
    public static let failureNotification = Notification.Name("SidePersistenceFailure")

    private var counts: [String: Int] = [:]

    public func report(url: URL, operation: Operation, error: Error) {
        let key = "\(operation.rawValue):\(url.path)"
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        NSLog("[Side] persistence %@ failed for %@: %@", operation.rawValue, url.path, error.localizedDescription)
        guard count == 1 else { return }
        let failure = Failure(url: url, operation: operation, error: error, occurrenceCount: count)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.failureNotification, object: failure)
        }
    }

    /// Test seam — lets a test observe the first-failure behavior without inheriting counts from
    /// whatever ran before it.
    public func resetCounts() { counts.removeAll() }

    public init() {}
}
