import Foundation

/// Side's own record of a conversation with an outside agent (`SIDE_RFC_BYO_HARNESS.md` step 5,
/// D5): what Think showed, one JSON line per entry, appended as the conversation goes, plus the
/// agent's session id so the agent's own session can be reopened (`session/load`).
///
/// It is a record of what Side rendered, not the agent's transcript: the agent keeps that
/// itself. Resolved cards are stored as their outcome (an approval card becomes "Allowed"), since
/// nothing is left to decide once a turn has ended. Tool and failure text passes through
/// `SecretRedactor`, as Heron's tool results do.
enum OutsideSessionLog {
    struct Record: Codable, Equatable {
        enum Kind: String, Codable { case header, user, assistant, thinking, tool, meta, failure, checkpoint }
        var kind: Kind
        var text: String = ""
        var detail: String?
        var checkpointId: UUID?
        /// On a header: the conversation and the agent's session it belongs to.
        var conversationId: UUID?
        var agentId: String?
        var agentSessionId: String?
        var at = Date()
    }

    struct Contents {
        var conversationId: UUID?
        var agentSessionId: String?
        var entries: [RunTranscriptEntry] = []
    }

    static func read(_ url: URL) -> Contents {
        var contents = Contents()
        guard let data = try? Data(contentsOf: url) else { return contents }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Line by line: a truncated last line (a kill mid-write) costs that line, not the file.
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            switch record.kind {
            case .header:
                contents.conversationId = record.conversationId ?? contents.conversationId
                contents.agentSessionId = record.agentSessionId ?? contents.agentSessionId
            default:
                if let kind = entryKind(record) { contents.entries.append(RunTranscriptEntry(kind: kind, createdAt: record.at)) }
            }
        }
        return contents
    }

    /// The last record of a kind, reading the file from its end (a window at a time), so a
    /// long conversation isn't read whole to find its latest answer.
    static func lastRecord(of kind: Record.Kind, in url: URL, window: Int = 64 * 1024) -> Record? {
        var found: Record?
        scanBackwards(url, window: window, cheapFilter: "\"\(kind.rawValue)\"") { record in
            guard record.kind == kind else { return false }
            found = record
            return true
        }
        return found
    }

    /// What the agent said in the turn that made a checkpoint: the last assistant text before
    /// the checkpoint's record, within that turn (it stops at the turn's prompt).
    static func account(forCheckpoint id: UUID, in url: URL, window: Int = 64 * 1024) -> Record? {
        var seenCheckpoint = false
        var found: Record?
        scanBackwards(url, window: window, cheapFilter: nil) { record in
            if !seenCheckpoint {
                seenCheckpoint = record.kind == .checkpoint && record.checkpointId == id
                return false
            }
            switch record.kind {
            case .assistant where !record.text.isEmpty: found = record; return true
            case .user, .checkpoint, .header: return true
            default: return false
            }
        }
        return found
    }

    /// Records from the end of the file back, until `visit` says stop. `cheapFilter` skips
    /// lines without that text before decoding them.
    private static func scanBackwards(_ url: URL, window: Int, cheapFilter: String?, visit: (Record) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let filter = cheapFilter.map { Data($0.utf8) }
        var end = size
        var carry = Data()
        while end > 0 {
            let start = end > UInt64(window) ? end - UInt64(window) : 0
            try? handle.seek(toOffset: start)
            guard var chunk = try? handle.read(upToCount: Int(end - start)) else { return }
            chunk.append(carry)
            var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            // The first line may be cut off by the window; it's read whole with the next one.
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where !line.isEmpty {
                if let filter, line.range(of: filter) == nil { continue }
                guard let record = try? decoder.decode(Record.self, from: line) else { continue }
                if visit(record) { return }
            }
            end = start
        }
    }

    /// The agent a record belongs to, from its header (the first line).
    static func agentId(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let line = data.split(separator: 0x0A).first else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Record.self, from: line))?.agentId
    }

    @discardableResult
    static func append(_ records: [Record], to url: URL) -> Bool {
        guard !records.isEmpty else { return true }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    /// A finished entry as a record, or nil for what isn't worth keeping (a card still open).
    static func record(for entry: RunTranscriptEntry) -> Record? {
        let redact = SecretRedactor.redacted
        var record: Record
        switch entry.kind {
        case .userText(let text): record = Record(kind: .user, text: text)
        case .assistantText(let text): record = Record(kind: .assistant, text: text)
        case .thinking(let text): record = Record(kind: .thinking, text: text)
        case .toolCall(let name, let summary): record = Record(kind: .tool, text: name, detail: redact(summary))
        case .meta(let text): record = Record(kind: .meta, text: text)
        case .failure(let text): record = Record(kind: .failure, text: redact(text))
        case .checkpoint(let id, let text): record = Record(kind: .checkpoint, text: text, checkpointId: id)
        case .permissionRequest(let presentation):
            guard let chosen = presentation.chosenOptionName else { return nil }
            record = Record(kind: .tool, text: presentation.title, detail: " · \(chosen)")
        case .proposal(let presentation):
            guard let resolution = presentation.resolution else { return nil }
            record = Record(kind: .tool, text: "Edit \(presentation.edit.relativePath)", detail: " · \(resolution.label.text)")
        default:
            return nil
        }
        record.at = entry.createdAt
        return record
    }

    private static func entryKind(_ record: Record) -> RunTranscriptEntry.Kind? {
        switch record.kind {
        case .header: return nil
        case .user: return .userText(record.text)
        case .assistant: return .assistantText(record.text)
        case .thinking: return .thinking(record.text)
        case .tool: return .toolCall(name: record.text, summary: record.detail ?? "")
        case .meta: return .meta(record.text)
        case .failure: return .failure(record.text)
        case .checkpoint: return record.checkpointId.map { .checkpoint(id: $0, text: record.text) }
        }
    }
}
