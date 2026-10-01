import Foundation

/// Lightweight, always-resident stand-in for a session's `turns` — everything the ledger/Think
/// header needs to know about a track's conversation without paying for its full history.
private struct SessionIndexEntry: Codable {
    public let id: UUID
    public let trackKey: String
    public var providerId: String
    public var modelId: String
    public var lastActiveAt: Date
    /// Lives here rather than in the log's header for the same reason provider/model do: the
    /// header is written once, at creation, which is precisely what lets an append write only
    /// the new turn — while this changes on every request. The index is small and already
    /// rewritten per turn.
    public var lastReportedInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case id, trackKey, providerId, modelId, lastActiveAt, lastReportedInputTokens
    }

    public init(id: UUID, trackKey: String, providerId: String, modelId: String, lastActiveAt: Date, lastReportedInputTokens: Int? = nil) {
        self.id = id
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.lastActiveAt = lastActiveAt
        self.lastReportedInputTokens = lastReportedInputTokens
    }

    // Tolerant, like every other persisted struct here: an index written before this field
    // existed must still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? Date()
        lastReportedInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastReportedInputTokens)
    }
}

/// Persists Think conversations *and* checkpoints per project. Checkpoints are cheap (no file
/// content, just metadata — see `Checkpoint.swift`) and stay eagerly loaded, same as before. A
/// session's `turns`, however, can hold arbitrarily large tool-result/assistant text (up to
/// `ToolExecutor.maxOutputCharacters` per tool result alone), and the old design loaded *every*
/// track's entire history for the whole project at init and never evicted any of it — the direct
/// cause of Think's memory footprint growing with total project history rather than with what's
/// actually being looked at. Now: only a lightweight index (this file) is eager; a track's full
/// `AgentSession` loads from its own file on first access and stays resident only for tracks
/// actually visited this run, not the whole project.
public final class AgentSessionStore {
    private var index: [SessionIndexEntry] = []
    private var checkpoints: [Checkpoint] = []
    /// Full sessions loaded so far this run, keyed by track key — grows only with tracks this
    /// process has actually touched, never with the project's total track count.
    private var loadedSessions: [String: AgentSession] = [:]

    private var archives: [ArchivedConversation] = []

    private let sessionsDirectory: URL
    /// Archived conversations, alongside the live ones rather than mixed in with them, so a
    /// directory listing still answers "what is current".
    private let archivesDirectory: URL
    /// Side's records of conversations with outside agents (harness RFC step 5): the current one
    /// per track and agent, and earlier ones kept under `archive/` when a new one starts.
    private let outsideDirectory: URL
    private let indexURL: URL
    private let archivesURL: URL
    /// Before checkpoints were kept per track: read once, split, removed.
    private let checkpointsURL: URL
    /// One file per track (D7): a checkpoint rewrote every checkpoint in the project, two or
    /// three times.
    private let checkpointsDirectory: URL
    /// Where `think.json` (the old single-file format) used to live — read once for migration,
    /// then removed once its contents are safely split across the new files.
    private let legacyURL: URL

    public init(stateDirectory: URL) {
        let thinkDirectory = stateDirectory.appendingPathComponent("think")
        self.sessionsDirectory = thinkDirectory.appendingPathComponent("sessions")
        self.archivesDirectory = thinkDirectory.appendingPathComponent("archive")
        self.outsideDirectory = thinkDirectory.appendingPathComponent("outside")
        self.indexURL = thinkDirectory.appendingPathComponent("index.json")
        self.archivesURL = thinkDirectory.appendingPathComponent("archives.json")
        self.checkpointsURL = thinkDirectory.appendingPathComponent("checkpoints.json")
        self.checkpointsDirectory = thinkDirectory.appendingPathComponent("checkpoints")
        self.legacyURL = stateDirectory.appendingPathComponent("think.json")
        // A store that closed a moment ago may still have its index waiting to be written.
        JSONStore.flushPendingWrites()
        load()
    }

    public func session(forTrackKey trackKey: String) -> AgentSession? {
        loadedSession(forTrackKey: trackKey)
    }

    /// Appends a turn to the track's session, creating the session on first use. Returns the
    /// updated session.
    @discardableResult
    public func appendTurn(_ turn: AgentTurn, trackKey: String, providerId: String, modelId: String) -> AgentSession {
        var session = loadedSession(forTrackKey: trackKey) ?? AgentSession(trackKey: trackKey, providerId: providerId, modelId: modelId)
        session.turns.append(turn)
        session.providerId = providerId
        session.modelId = modelId
        session.lastActiveAt = Date()
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        // The hot path: one appended line, not a full re-serialization of the conversation.
        // Falls back to a full write when there's no file yet (first turn) or the append fails.
        if !SessionLog.append(turn, to: sessionFileURL(forTrackKey: trackKey)) {
            saveSession(session)
        }
        if let indexPosition = index.firstIndex(where: { $0.trackKey == trackKey }) {
            index[indexPosition].providerId = providerId
            index[indexPosition].modelId = modelId
            index[indexPosition].lastActiveAt = session.lastActiveAt
        } else {
            index.append(SessionIndexEntry(id: session.id, trackKey: trackKey, providerId: providerId, modelId: modelId, lastActiveAt: session.lastActiveAt))
        }
        saveIndex()
        return session
    }

    /// Wholesale replacement of a track's turns — how compaction lands. Deliberately not an
    /// in-place edit of `turns`: the replacement has to be written and re-read as one unit, or a
    /// crash mid-compaction could leave half a conversation.
    @discardableResult
    public func replaceTurns(_ turns: [AgentTurn], trackKey: String, providerId: String, modelId: String) -> AgentSession {
        var session = loadedSession(forTrackKey: trackKey) ?? AgentSession(trackKey: trackKey, providerId: providerId, modelId: modelId)
        session.turns = turns
        session.lastActiveAt = Date()
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        saveSession(session)
        if let indexPosition = index.firstIndex(where: { $0.trackKey == trackKey }) {
            index[indexPosition].lastActiveAt = session.lastActiveAt
        } else {
            index.append(SessionIndexEntry(id: session.id, trackKey: trackKey, providerId: providerId, modelId: modelId, lastActiveAt: session.lastActiveAt))
        }
        saveIndex()
        return session
    }

    // MARK: - Compaction and its Undo

    /// Replaces the conversation with its summary, keeping what it replaced for Undo. The old
    /// conversation is written first: if that fails, nothing is replaced.
    @discardableResult
    public func compactTurns(into summary: AgentTurn, trackKey: String, providerId: String, modelId: String) -> AgentSession? {
        guard let session = loadedSession(forTrackKey: trackKey), !session.turns.isEmpty,
              SessionLog.write(session, to: compactedFileURL(forTrackKey: trackKey)) else { return nil }
        return replaceTurns([summary], trackKey: trackKey, providerId: providerId, modelId: modelId)
    }

    public func canUndoCompaction(forTrackKey trackKey: String) -> Bool {
        FileManager.default.fileExists(atPath: compactedFileURL(forTrackKey: trackKey).path)
    }

    /// The conversation before its compaction, followed by whatever was said since (the summary
    /// itself dropped). Nil when there's nothing to undo.
    @discardableResult
    public func undoCompaction(forTrackKey trackKey: String, providerId: String, modelId: String) -> AgentSession? {
        let url = compactedFileURL(forTrackKey: trackKey)
        guard let before = SessionLog.read(from: url), let current = loadedSession(forTrackKey: trackKey) else { return nil }
        let since = current.turns.first.map { $0.isCompactionSummary } == true ? Array(current.turns.dropFirst()) : current.turns
        let restored = replaceTurns(before.turns + since, trackKey: trackKey, providerId: providerId, modelId: modelId)
        try? FileManager.default.removeItem(at: url)
        return restored
    }

    /// Undo is for the compaction just made; a conversation started over can't return to it.
    public func discardCompactionUndo(forTrackKey trackKey: String) {
        try? FileManager.default.removeItem(at: compactedFileURL(forTrackKey: trackKey))
    }

    public func checkpoints(forTrackKey trackKey: String) -> [Checkpoint] {
        checkpoints.filter { $0.trackKey == trackKey }
    }

    /// Attaches a verification result to the most recent checkpoint on a track.
    ///
    /// Most recent, rather than "the checkpoint that produced the change": a task runs in a
    /// later round trip than the edit it verifies, and by then the batch that made the change
    /// is closed. The newest checkpoint is the one the task was run *against*, which is what
    /// the user means by "did that work?".
    @discardableResult
    public func attachVerification(_ verification: CheckpointVerification, toLatestCheckpointFor trackKey: String) -> Bool {
        guard let index = checkpoints.lastIndex(where: { $0.trackKey == trackKey }) else { return false }
        checkpoints[index].verification = verification
        saveCheckpoints(trackKey: trackKey)
        notifyCheckpointsChanged()
        return true
    }

    /// Records the provider's measured input-token count for a track's most recent request.
    ///
    /// Kept out of `appendTurn` on purpose: the count arrives with the response, which is a
    /// different moment from the turns being written, and conflating them would mean either
    /// writing the index twice per turn or losing the count on the turn that produced it.
    public func recordReportedInputTokens(_ tokens: Int?, forTrackKey trackKey: String) {
        guard let position = index.firstIndex(where: { $0.trackKey == trackKey }) else { return }
        guard index[position].lastReportedInputTokens != tokens else { return }
        index[position].lastReportedInputTokens = tokens
        loadedSessions[trackKey]?.lastReportedInputTokens = tokens
        saveIndex()
    }

    /// Replaces a checkpoint's description once the agent has said what it did.
    ///
    /// The description has to be written twice because the two facts arrive at different times:
    /// the checkpoint is created the moment its batch resolves, but the agent's account of the
    /// change comes in the *next* turn. Recording the user's request first and upgrading it to
    /// the agent's summary is strictly better than either alone — there is never a moment where
    /// a checkpoint has no description, and the final one describes what happened rather than
    /// what was asked for.
    @discardableResult
    public func updateCheckpointDescription(_ description: String, id: UUID) -> Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let position = checkpoints.firstIndex(where: { $0.id == id }) else { return false }
        checkpoints[position].declaredIntent = trimmed
        saveCheckpoints(trackKey: checkpoints[position].trackKey)
        notifyCheckpointsChanged()
        return true
    }

    /// Posted whenever the checkpoint ledger changes — appended, renamed, or verified.
    ///
    /// Review used to refresh only when the stage was entered, so a checkpoint created while the
    /// user was already looking at Review didn't appear until they left and came back. Reported as
    /// exactly that. A notification rather than an observer list because the store has no notion of
    /// which views exist, and more than one surface wants this (Review today; the Tracks ledger's
    /// checkpoint counts next).
    public static let checkpointsDidChangeNotification = Notification.Name("SideCheckpointsDidChange")

    public func appendCheckpoint(_ checkpoint: Checkpoint) {
        checkpoints.append(checkpoint)
        saveCheckpoints(trackKey: checkpoint.trackKey)
        notifyCheckpointsChanged()
    }

    private func notifyCheckpointsChanged() {
        NotificationCenter.default.post(name: Self.checkpointsDidChangeNotification, object: nil)
    }

    // MARK: - The agent's account (Review's summary)

    /// What the agent said in the turn that made a checkpoint, for Review's summary: its words
    /// about that work, not whatever it said last (a question, a greeting). Outside agents'
    /// records mark the checkpoint, so it's the last answer before that mark; for Heron's own
    /// conversation, the last answer at or before the checkpoint was made. Reads only the end of
    /// each record, so a long conversation costs what its last few entries do.
    public func agentAccount(for checkpoint: Checkpoint) -> AgentAccount? {
        let prefix = Self.slug(for: checkpoint.trackKey) + "."
        let current = ((try? FileManager.default.contentsOfDirectory(at: outsideDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix(prefix) }
        for url in current {
            if let record = OutsideSessionLog.account(forCheckpoint: checkpoint.id, in: url) {
                return AgentAccount(text: record.text, at: record.at, agentId: OutsideSessionLog.agentId(in: url))
            }
        }
        guard !checkpoint.provenance.providerId.hasPrefix("acp:"),
              let session = loadedSessions[checkpoint.trackKey] ?? loadedSession(forTrackKey: checkpoint.trackKey) else { return nil }
        let made = checkpoint.createdAt.addingTimeInterval(1)
        // Within the turn: an answer after the last prompt before the checkpoint.
        let turns = session.turns.filter { $0.createdAt <= made }
        guard let lastPrompt = turns.lastIndex(where: { $0.role == .user && $0.content.contains { if case .text = $0 { return true } else { return false } } }) else { return nil }
        for turn in turns[lastPrompt...].reversed() where turn.role == .assistant {
            let text = turn.content.compactMap { block -> String? in if case .text(let t) = block { return t } else { return nil } }.joined(separator: "\n\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentAccount(text: text, at: turn.createdAt, agentId: nil)
            }
        }
        return nil
    }

    // MARK: - Outside agents' conversations

    /// Where the current conversation with `agentId` on a track is recorded.
    public func outsideLogURL(trackKey: String, agentId: String) -> URL {
        outsideDirectory.appendingPathComponent("\(Self.slug(for: trackKey)).\(Self.slug(for: agentId)).jsonl")
    }

    /// Files the current conversation away (New Conversation) and returns its archived location.
    @discardableResult
    public func archiveOutsideLog(trackKey: String, agentId: String) -> URL? {
        let current = outsideLogURL(trackKey: trackKey, agentId: agentId)
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }
        let archived = outsideDirectory.appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent(current.deletingPathExtension().lastPathComponent + "-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6)).jsonl")
        try? FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? FileManager.default.moveItem(at: current, to: archived)) != nil ? archived : nil
    }

    private var outsideArchiveDirectory: URL { outsideDirectory.appendingPathComponent("archive", isDirectory: true) }

    /// Past conversations with `agentId` on a track, newest first, for Think's History. Each is
    /// identified by its own conversation id, from its record's header.
    public func outsideArchives(trackKey: String, agentId: String) -> [ArchivedConversation] {
        outsideArchiveFiles(trackKey: trackKey, agentId: agentId).compactMap { url in
            let contents = OutsideSessionLog.read(url)
            guard let id = contents.conversationId else { return nil }
            let firstUser = contents.entries.lazy.compactMap { entry -> String? in
                if case .userText(let text) = entry.kind { return text }
                return nil
            }.first ?? ""
            let oneLine = firstUser.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let archivedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let turns = contents.entries.filter { if case .userText = $0.kind { return true } else { return false } }.count
            return ArchivedConversation(id: id, trackKey: trackKey, title: oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine,
                                        turnCount: turns, createdAt: contents.entries.first?.createdAt ?? archivedAt, archivedAt: archivedAt)
        }.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Makes an archived conversation current again, filing the current one away first. False if
    /// it isn't there.
    @discardableResult
    public func openOutsideArchive(id: UUID, trackKey: String, agentId: String) -> Bool {
        guard let file = outsideArchiveFiles(trackKey: trackKey, agentId: agentId).first(where: { OutsideSessionLog.read($0).conversationId == id }) else { return false }
        archiveOutsideLog(trackKey: trackKey, agentId: agentId)
        return (try? FileManager.default.moveItem(at: file, to: outsideLogURL(trackKey: trackKey, agentId: agentId))) != nil
    }

    private func outsideArchiveFiles(trackKey: String, agentId: String) -> [URL] {
        let prefix = outsideLogURL(trackKey: trackKey, agentId: agentId).deletingPathExtension().lastPathComponent + "-"
        return ((try? FileManager.default.contentsOfDirectory(at: outsideArchiveDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Every outside-agent record for a track, current and archived.
    private func outsideLogs(trackKey: String?) -> [URL] {
        let prefix = trackKey.map { Self.slug(for: $0) + "." }
        return [outsideDirectory, outsideDirectory.appendingPathComponent("archive")].flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { url in url.pathExtension == "jsonl" && (prefix.map { url.lastPathComponent.hasPrefix($0) } ?? true) }
        }
    }

    /// Called when a track is deleted — its conversation and checkpoints have nowhere to belong
    /// anymore, same cleanup contract as Make's file memory and Run's terminal sessions.
    public func removeSession(forTrackKey trackKey: String) {
        for record in archives where record.trackKey == trackKey {
            try? FileManager.default.removeItem(at: archiveFileURL(id: record.id))
        }
        archives.removeAll { $0.trackKey == trackKey }
        saveArchives()
        loadedSessions.removeValue(forKey: trackKey)
        residency.removeAll { $0 == trackKey }
        index.removeAll { $0.trackKey == trackKey }
        checkpoints.removeAll { $0.trackKey == trackKey }
        try? FileManager.default.removeItem(at: checkpointsFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: compactedFileURL(forTrackKey: trackKey))
        for url in outsideLogs(trackKey: trackKey) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        saveIndex()
        notifyCheckpointsChanged()
    }

    // MARK: - Lazy session loading

    /// Most-recently-used track keys, oldest first. The lazy-load fix stopped *eagerly*
    /// loading every track's history, but nothing evicted, so memory scaled with tracks
    /// ever visited rather than tracks in use — browsing eight tracks kept eight full
    /// conversations resident for the life of the project.
    private var residency: [String] = []
    private static let maxResidentSessions = 3

    private func touchResidency(_ trackKey: String) {
        residency.removeAll { $0 == trackKey }
        residency.append(trackKey)
        while residency.count > Self.maxResidentSessions {
            let evicted = residency.removeFirst()
            // Safe to drop: every mutation writes through to disk before returning, so the
            // cache is never the only copy of anything.
            loadedSessions.removeValue(forKey: evicted)
        }
    }

    private func loadedSession(forTrackKey trackKey: String) -> AgentSession? {
        if let cached = loadedSessions[trackKey] {
            touchResidency(trackKey)
            return cached
        }
        guard index.contains(where: { $0.trackKey == trackKey }) else { return nil }
        var session: AgentSession
        if let logged = SessionLog.read(from: sessionFileURL(forTrackKey: trackKey)) {
            session = logged
        } else if let legacy = JSONStore.read(AgentSession.self, from: legacySessionFileURL(forTrackKey: trackKey))?.payload {
            // One-time migration to the append-only log, then the old file goes away.
            session = legacy
            SessionLog.write(session, to: sessionFileURL(forTrackKey: trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        } else {
            return nil
        }
        // The index is authoritative for the mutable metadata it carries (see
        // `SessionIndexEntry`), so it wins over whatever the log header was created with.
        if let entry = index.first(where: { $0.trackKey == trackKey }) {
            session.lastReportedInputTokens = entry.lastReportedInputTokens
        }
        // Repair before anything can read it — a session with a dangling tool_use is not just
        // cosmetically odd, it's unusable (see `Self.repairingDanglingToolUses`).
        if let repaired = Self.repairingDanglingToolUses(session) {
            session = repaired
            saveSession(session)
        }
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        return session
    }

    /// Returns a repaired copy when the session contains `tool_use` blocks that no `tool_result`
    /// ever answers, or `nil` when nothing needed fixing.
    ///
    /// `AgentRunner.teardown()` writes synthetic rejections for pending proposals, but only on a
    /// *graceful* shutdown. Force-quit, a crash, or power loss between persisting the assistant's
    /// tool_use turn and persisting its results leaves the conversation permanently broken rather
    /// than merely incomplete: the full turn list is replayed to the provider on every send, and
    /// a tool_use with no matching tool_result is a protocol violation the API rejects outright —
    /// so every future message in that track fails. Repairing at load time (rather than only at
    /// teardown) is what makes recovery independent of *how* the process died, and also fixes
    /// sessions already on disk in that state.
    ///
    /// Synthesizing a rejection is the honest repair: nothing was applied, because approval never
    /// happened. The result is inserted immediately after the assistant turn that made the call,
    /// which is where the wire format requires it.
    public static func repairingDanglingToolUses(_ session: AgentSession) -> AgentSession? {
        var answeredIds = Set<String>()
        for turn in session.turns {
            for block in turn.content {
                if case .toolResult(let toolUseId, _, _) = block { answeredIds.insert(toolUseId) }
            }
        }

        var repairedTurns: [AgentTurn] = []
        var didRepair = false
        for turn in session.turns {
            repairedTurns.append(turn)
            let unanswered = turn.content.compactMap { block -> String? in
                guard case .toolUse(let id, _, _) = block, !answeredIds.contains(id) else { return nil }
                return id
            }
            guard !unanswered.isEmpty else { continue }
            didRepair = true
            repairedTurns.append(AgentTurn(role: .user, content: unanswered.map {
                .toolResult(
                    toolUseId: $0,
                    content: "Side closed before the user decided, so this never ran and nothing changed. Ask again if it's still needed.",
                    isError: true
                )
            }))
            answeredIds.formUnion(unanswered)
        }
        guard didRepair else { return nil }
        var repaired = session
        repaired.turns = repairedTurns
        return repaired
    }

    /// Branch-name-shaped track keys can contain `/`; `""` means "no active track" — both need a
    /// safe, unique filename, same sanitization convention `GitPaths`/`TrackStore` already use
    /// for worktree directory names.
    private func sessionFileURL(forTrackKey trackKey: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(Self.slug(for: trackKey)).jsonl")
    }

    /// The conversation as it was before its last compaction, kept for Undo
    /// (SIDE_RFC_HERON_EFFICIENCY.md, D4). Beside the session rather than in it: the session's
    /// header is one line, and this is a whole conversation.
    private func compactedFileURL(forTrackKey trackKey: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(Self.slug(for: trackKey)).compacted.jsonl")
    }

    /// The pre-JSONL filename, still read once so an existing conversation migrates instead of
    /// vanishing.
    private func legacySessionFileURL(forTrackKey trackKey: String) -> URL {
        let slug = trackKey.isEmpty ? "_none_" : trackKey.replacingOccurrences(of: "/", with: "-")
        return sessionsDirectory.appendingPathComponent("\(slug).json")
    }

    /// A filesystem-safe name that can't collide. The old form just mapped `/`→`-`, so the
    /// branches `feat/x` and `feat-x` — both reachable, since either can be adopted as a track —
    /// shared one conversation file and silently merged two conversations. The suffix is derived
    /// from the full key, so distinct keys stay distinct however they're spelled.
    private static func slug(for trackKey: String) -> String {
        guard !trackKey.isEmpty else { return "_none_" }
        let safe = String(trackKey.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(60))
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(trackKey.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(safe)-\(String(hash, radix: 36))"
    }

    // MARK: - Persistence

    /// Everything loads whatever state the index is in (2026-09-30 audit, R3 and GIT-5): a
    /// missing or corrupt index used to leave checkpoints and archives unloaded, so the next
    /// checkpoint overwrote a track's records with one, and a session written just before a
    /// crash, whose index entry hadn't been, couldn't be found. The index is reconciled with
    /// the session files on disk instead.
    private func load() {
        if !FileManager.default.fileExists(atPath: indexURL.path) { migrateLegacyStateIfPresent() }
        index = JSONStore.read([SessionIndexEntry].self, from: indexURL)?.payload ?? []
        archives = JSONStore.read([ArchivedConversation].self, from: archivesURL)?.payload ?? []
        checkpoints = loadCheckpoints()
        writtenIndexKeys = Set(index.map(\.trackKey))
        if reconcileIndexWithSessionFiles() { saveIndex() }
        pruneExpiredSessions()
    }

    /// Adds an entry for every session file the index doesn't name. True when it added any.
    private func reconcileIndexWithSessionFiles() -> Bool {
        let known = Set(index.map { Self.slug(for: $0.trackKey) })
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        var added = false
        for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasSuffix(".compacted.jsonl") {
            guard !known.contains(file.deletingPathExtension().lastPathComponent), let session = SessionLog.read(from: file) else { continue }
            index.append(SessionIndexEntry(id: session.id, trackKey: session.trackKey, providerId: session.providerId,
                                           modelId: session.modelId, lastActiveAt: session.lastActiveAt,
                                           lastReportedInputTokens: session.lastReportedInputTokens))
            added = true
        }
        return added
    }

    /// Applies the user's retention setting. At load, rather than on a timer: a project's
    /// history can only expire while someone's looking at that project, and a background sweep
    /// deleting files for projects nobody has open is a worse trade than a slightly late one.
    private func pruneExpiredSessions() {
        guard let cutoff = HistoryRetention.current.cutoffDate() else { return }
        // Outside agents' records hold the same kind of content; the same window applies.
        for url in outsideLogs(trackKey: nil) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        let expired = index.filter { $0.lastActiveAt < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired {
            loadedSessions.removeValue(forKey: entry.trackKey)
            try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: compactedFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: entry.trackKey))
        }
        index.removeAll { $0.lastActiveAt < cutoff }
        saveIndex()
    }

    /// Drops every conversation in this project, keeping tracks and checkpoints. The blunt
    /// instrument behind Preferences' "Delete All Conversations."
    public func deleteAllSessions() {
        for record in archives {
            try? FileManager.default.removeItem(at: archiveFileURL(id: record.id))
        }
        archives.removeAll()
        saveArchives()
        for url in outsideLogs(trackKey: nil) { try? FileManager.default.removeItem(at: url) }
        loadedSessions.removeAll()
        residency.removeAll()
        for entry in index {
            try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: compactedFileURL(forTrackKey: entry.trackKey))
            try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: entry.trackKey))
        }
        index.removeAll()
        saveIndex()
    }

    /// One-time split of the old single `think.json` (every track's full history, eagerly
    /// loaded) into the new per-track-file layout. Runs at most once per project — `load()` only
    /// calls this when `index.json` doesn't exist yet, and this writes `index.json` as its last
    /// step, so a second launch never re-enters this path.
    private func migrateLegacyStateIfPresent() {
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var legacySessions: [AgentSession] = []
        var legacyCheckpoints: [Checkpoint] = []
        if let decoded = try? decoder.decode(ThinkStateLegacy.self, from: data) {
            legacySessions = decoded.sessions
            legacyCheckpoints = decoded.checkpoints
        } else if let decoded = try? decoder.decode([AgentSession].self, from: data) {
            // Pre-checkpoint think.json was a bare `[AgentSession]` array.
            legacySessions = decoded
        } else {
            return
        }
        checkpoints = legacyCheckpoints
        index = legacySessions.map { SessionIndexEntry(id: $0.id, trackKey: $0.trackKey, providerId: $0.providerId, modelId: $0.modelId, lastActiveAt: $0.lastActiveAt) }
        let sessionsWritten = legacySessions.allSatisfy { SessionLog.write($0, to: sessionFileURL(forTrackKey: $0.trackKey)) }
        let indexWritten = JSONStore.write(index, to: indexURL, compact: true)
        let checkpointsWritten = Set(checkpoints.map(\.trackKey)).allSatisfy { saveCheckpoints(trackKey: $0) }
        // Only once all of it is safely written (2026-09-30 audit, GIT-7).
        if sessionsWritten, indexWritten, checkpointsWritten { try? FileManager.default.removeItem(at: legacyURL) }
    }

    /// A moment later, compact, and once for however many changes (D7: it was written whole,
    /// pretty-printed, on every turn). The sessions themselves are written as they change; this
    /// is their directory.
    private func saveIndex() {
        // A track gaining or losing its entry is written now; a crash in the delay otherwise hid
        // a conversation (2026-09-30 audit, GIT-5). Only the entries' metadata waits.
        let keys = Set(index.map(\.trackKey))
        guard keys == writtenIndexKeys, FileManager.default.fileExists(atPath: indexURL.path) else {
            if JSONStore.write(index, to: indexURL, compact: true) { writtenIndexKeys = keys }
            return
        }
        JSONStore.writeSoon(to: indexURL) { self.index }
    }

    /// The tracks the index on disk names.
    private var writtenIndexKeys: Set<String> = []

    // MARK: - Conversation history

    /// Past conversations for a track, newest first.
    public func archivedConversations(forTrackKey trackKey: String) -> [ArchivedConversation] {
        archives.filter { $0.trackKey == trackKey }.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Files the track's current conversation away and clears the live slot.
    ///
    /// Returns false when there is nothing worth keeping — an empty conversation is not history,
    /// and archiving it would fill the picker with blank rows.
    @discardableResult
    public func archiveActiveConversation(forTrackKey trackKey: String) -> Bool {
        guard let session = loadedSession(forTrackKey: trackKey), !session.turns.isEmpty else { return false }
        let record = ArchivedConversation(
            id: session.id, trackKey: trackKey,
            title: ArchivedConversation.title(for: session),
            turnCount: session.turns.count,
            createdAt: session.createdAt
        )
        // Written before the live copy is cleared: if this fails the conversation is still where
        // it was, which is the safe direction for a failure whose alternative is losing it.
        guard SessionLog.write(session, to: archiveFileURL(id: session.id)) else { return false }
        archives.append(record)
        saveArchives()
        clearActiveConversation(forTrackKey: trackKey)
        return true
    }

    /// Forks the conversation at a user turn: the whole thing is filed away as a branch, and the
    /// live conversation is rewound to just before that turn so an edited message can take its
    /// place.
    ///
    /// Nothing is deleted. That is the entire difference between this and how Cursor or ChatGPT
    /// handle an edited message — there, the discarded turns become a hidden alternate the rest of
    /// the app can't see. Here the branch is an ordinary conversation in the history picker, which
    /// matters because a discarded turn may have applied an edit that is still on disk and still
    /// in Review as a checkpoint. A record the user can't reach would leave those checkpoints
    /// belonging to a conversation that, as far as the app was concerned, never happened.
    ///
    /// Returns the turns that were rewound past, so the caller can tell the user (and the model)
    /// what those turns already did. `nil` when the turn isn't a user turn or isn't in this
    /// conversation — both are programming errors rather than states worth reporting.
    public struct ConversationBranch {
        public let record: ArchivedConversation
        /// Turns the live conversation no longer has, oldest first — including the edited one.
        public let removedTurns: [AgentTurn]
        public let session: AgentSession

        public init(record: ArchivedConversation, removedTurns: [AgentTurn], session: AgentSession) {
            self.record = record
            self.removedTurns = removedTurns
            self.session = session
        }
    }

    public func branchConversation(atTurnId turnId: UUID, forTrackKey trackKey: String) -> ConversationBranch? {
        guard var session = loadedSession(forTrackKey: trackKey),
              let position = session.turns.firstIndex(where: { $0.id == turnId }),
              session.turns[position].role == .user else { return nil }

        // A fresh id: the live conversation keeps its own, so the branch cannot reuse it without
        // the two colliding in `archives` and in the archive filenames.
        let branchId = UUID()
        let complete = AgentSession(
            id: branchId, trackKey: trackKey, providerId: session.providerId, modelId: session.modelId,
            turns: session.turns, createdAt: session.createdAt, lastActiveAt: session.lastActiveAt,
            lastReportedInputTokens: session.lastReportedInputTokens
        )
        // Titled by the message being edited away, not by the conversation's first message — a
        // branch and its parent share that prefix, so the ordinary title would file both under
        // the same name and the picker would offer two identical rows.
        let record = ArchivedConversation(
            id: branchId, trackKey: trackKey,
            title: Self.branchTitle(for: session.turns[position]),
            turnCount: session.turns.count, createdAt: session.createdAt,
            branchPointTurnIndex: position
        )
        // Written before the live copy is truncated, same order and same reason as archiving:
        // a failure here leaves the conversation exactly as it was.
        guard SessionLog.write(complete, to: archiveFileURL(id: branchId)) else { return nil }

        let removed = Array(session.turns[position...])
        session.turns = Array(session.turns[..<position])
        session.lastActiveAt = Date()
        loadedSessions[trackKey] = session
        guard SessionLog.write(session, to: sessionFileURL(forTrackKey: trackKey)) else { return nil }
        archives.append(record)
        saveArchives()
        upsertIndexEntry(for: session, trackKey: trackKey)
        return ConversationBranch(record: record, removedTurns: removed, session: session)
    }

    /// The first line of the turn's text, which is what someone will recognize the branch by.
    private static func branchTitle(for turn: AgentTurn) -> String {
        for block in turn.content {
            guard case .text(let text) = block else { continue }
            let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oneLine.isEmpty else { continue }
            return oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine
        }
        return "Edited message"
    }

    /// Swaps an archived conversation back into the live slot, filing away whatever was there.
    ///
    /// The current conversation is archived first rather than discarded — reopening an old one
    /// must not be a way to lose the new one.
    @discardableResult
    public func openArchivedConversation(id: UUID, forTrackKey trackKey: String) -> AgentSession? {
        guard let record = archives.first(where: { $0.id == id && $0.trackKey == trackKey }),
              let session = SessionLog.read(from: archiveFileURL(id: id)) else { return nil }
        archiveActiveConversation(forTrackKey: trackKey)
        guard SessionLog.write(session, to: sessionFileURL(forTrackKey: trackKey)) else { return nil }
        try? FileManager.default.removeItem(at: archiveFileURL(id: id))
        archives.removeAll { $0.id == record.id }
        saveArchives()
        loadedSessions[trackKey] = session
        touchResidency(trackKey)
        upsertIndexEntry(for: session, trackKey: trackKey)
        return session
    }

    /// Removes the live conversation without keeping it — what `startNewConversation` used to do
    /// unconditionally, now reserved for a user who explicitly discards.
    public func clearActiveConversation(forTrackKey trackKey: String) {
        loadedSessions.removeValue(forKey: trackKey)
        residency.removeAll { $0 == trackKey }
        index.removeAll { $0.trackKey == trackKey }
        try? FileManager.default.removeItem(at: sessionFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: compactedFileURL(forTrackKey: trackKey))
        try? FileManager.default.removeItem(at: legacySessionFileURL(forTrackKey: trackKey))
        saveIndex()
    }

    private func archiveFileURL(id: UUID) -> URL {
        archivesDirectory.appendingPathComponent("\(id.uuidString).jsonl")
    }

    private func saveArchives() {
        JSONStore.write(archives, to: archivesURL)
    }

    private func upsertIndexEntry(for session: AgentSession, trackKey: String) {
        if let position = index.firstIndex(where: { $0.trackKey == trackKey }) {
            index[position].providerId = session.providerId
            index[position].modelId = session.modelId
            index[position].lastActiveAt = session.lastActiveAt
            index[position].lastReportedInputTokens = session.lastReportedInputTokens
        } else {
            index.append(SessionIndexEntry(
                id: session.id, trackKey: trackKey, providerId: session.providerId,
                modelId: session.modelId, lastActiveAt: session.lastActiveAt,
                lastReportedInputTokens: session.lastReportedInputTokens
            ))
        }
        saveIndex()
    }

    private func checkpointsFileURL(forTrackKey trackKey: String) -> URL {
        checkpointsDirectory.appendingPathComponent("\(Self.slug(for: trackKey)).json")
    }

    /// Only the one track's file. Written now, not debounced: a checkpoint is the record of what
    /// an agent changed.
    @discardableResult
    private func saveCheckpoints(trackKey: String) -> Bool {
        let url = checkpointsFileURL(forTrackKey: trackKey)
        let own = checkpoints.filter { $0.trackKey == trackKey }
        if own.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return JSONStore.write(own, to: url, compact: true)
    }

    /// Every track's file; the one-file ledger of before, split into them the first time.
    ///
    /// The old ledger is merged in by id, never over what the per-track files already hold (an
    /// older build writing it again mustn't erase checkpoints made since), and removed only once
    /// every write has succeeded (2026-09-30 audit, GIT-7: a full disk lost every record).
    private func loadCheckpoints() -> [Checkpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(at: checkpointsDirectory, includingPropertiesForKeys: nil)) ?? []
        var loaded = files.filter { $0.pathExtension == "json" }
            .flatMap { JSONStore.read([Checkpoint].self, from: $0)?.payload ?? [] }
        if let legacy = JSONStore.read([Checkpoint].self, from: checkpointsURL)?.payload {
            let known = Set(loaded.map(\.id))
            loaded += legacy.filter { !known.contains($0.id) }
            checkpoints = loaded
            let allWritten = Set(legacy.map(\.trackKey)).allSatisfy { saveCheckpoints(trackKey: $0) }
            if allWritten { try? FileManager.default.removeItem(at: checkpointsURL) }
        }
        return loaded.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveSession(_ session: AgentSession) {
        SessionLog.write(session, to: sessionFileURL(forTrackKey: session.trackKey))
    }
}

/// What an agent last said on a track, and when (`AgentSessionStore.latestAgentAccount`).
public struct AgentAccount: Equatable, Sendable {
    public let text: String
    public let at: Date
    /// The outside agent that said it; nil for Heron's own.
    public let agentId: String?
}

/// The old `think.json` shape — read only during one-time migration in `migrateLegacyStateIfPresent`.
private struct ThinkStateLegacy: Codable {
    public var sessions: [AgentSession] = []
    public var checkpoints: [Checkpoint] = []
}
