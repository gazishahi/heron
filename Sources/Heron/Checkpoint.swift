import Foundation

/// Where a checkpoint's changes came from — deliberately thin today (just enough to answer "what
/// model, whose key"); a real instruction-source summary (custom system prompts, skills) is a
/// later concern once those exist at all.
public struct AgentProvenance: Codable, Sendable {
    public let providerId: String
    public let modelId: String
    public let instructionSourceSummary: String

    public init(providerId: String, modelId: String, instructionSourceSummary: String) {
        self.providerId = providerId
        self.modelId = modelId
        self.instructionSourceSummary = instructionSourceSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        instructionSourceSummary = try container.decodeIfPresent(String.self, forKey: .instructionSourceSummary) ?? ""
    }
}

/// What a task run proved about a checkpoint's changes.
///
/// The gap this closes: an agent's central failure mode is claiming a fix works without
/// evidence, and until now nothing in Side ever established that approved work compiled, let
/// alone passed. A checkpoint is now one of verified / failed / unverified, and Review says
/// which — which is what lets promotion refuse work that is known broken rather than merely
/// unreviewed.
public struct CheckpointVerification: Codable, Equatable, Sendable {
    public let taskName: String
    public let command: String
    /// nil when the command never produced an exit status (interrupted, or the shell died).
    public let exitCode: Int?
    /// A bounded excerpt — enough to see what failed, not enough to bloat the record.
    public let outputExcerpt: String
    public let ranAt: Date

    public static let maxExcerptCharacters = 4_000

    public var passed: Bool { exitCode == 0 }

    public init(taskName: String, command: String, exitCode: Int?, output: String, ranAt: Date = Date()) {
        self.taskName = taskName
        self.command = command
        self.exitCode = exitCode
        // The tail, not the head: a failing build puts its errors at the end.
        self.outputExcerpt = output.count > Self.maxExcerptCharacters
            ? String(output.suffix(Self.maxExcerptCharacters))
            : output
        self.ranAt = ranAt
    }

    private enum CodingKeys: String, CodingKey {
        case taskName, command, exitCode, outputExcerpt, ranAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskName = try container.decodeIfPresent(String.self, forKey: .taskName) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        outputExcerpt = try container.decodeIfPresent(String.self, forKey: .outputExcerpt) ?? ""
        ranAt = try container.decodeIfPresent(Date.self, forKey: .ranAt) ?? Date()
    }
}

/// A durable record of one approved batch of changes — the constitution's "an agent run does not
/// equal a branch; it produces a durable checkpoint." Backed by a real git commit on the track's
/// own branch (in its own worktree), created automatically the moment every proposal in a batch
/// is resolved, provided at least one was actually applied or executed — never before approval,
/// never as a substitute for the approval click itself, just bookkeeping that follows it.
/// One file's line delta within a checkpoint.
///
/// Stored rather than recomputed because the alternative is a `git diff --numstat` subprocess on
/// the launch path, and process spawns are the one thing Side's launch budget cannot afford (see
/// `SIDE_LAUNCH_PERFORMANCE.md`). The numbers are already in hand when an edit is applied; keeping
/// them costs two integers per file.
public struct CheckpointFileChange: Codable, Equatable, Sendable {
    public let path: String
    public let added: Int
    public let removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct Checkpoint: Codable, Identifiable, Sendable {
    public let id: UUID
    public let trackKey: String
    public let agentSessionId: UUID
    /// `var` — written twice: the user's request when the checkpoint is created, then the
    /// agent's own account of the change when the turn that made it finishes. See
    /// `AgentSessionStore.updateCheckpointDescription`.
    public var declaredIntent: String
    public let changedFilePaths: [String]
    /// Per-file line deltas, when known. Empty for a checkpoint written before this was recorded —
    /// `changedFilePaths` is still authoritative for *which* files, so a reader shows the file
    /// list and simply has no numbers to show, rather than inventing zeros that look measured.
    public let fileChanges: [CheckpointFileChange]
    public let commandsRun: [String]
    public let provenance: AgentProvenance
    /// `nil` only for a checkpoint with zero file changes — e.g. every command in the batch ran
    /// but touched nothing, or ran and then reverted its own edits.
    public let gitCommitSHA: String?
    public let createdAt: Date
    /// `var` — verification usually arrives *after* the checkpoint, when the agent runs the
    /// project's test task in a later round trip.
    public var verification: CheckpointVerification?

    public init(trackKey: String, agentSessionId: UUID, declaredIntent: String, changedFilePaths: [String], commandsRun: [String], provenance: AgentProvenance, gitCommitSHA: String?, fileChanges: [CheckpointFileChange] = []) {
        self.id = UUID()
        self.trackKey = trackKey
        self.agentSessionId = agentSessionId
        self.declaredIntent = declaredIntent
        self.changedFilePaths = changedFilePaths
        self.fileChanges = fileChanges
        self.commandsRun = commandsRun
        self.provenance = provenance
        self.gitCommitSHA = gitCommitSHA
        self.createdAt = Date()
    }

    // Tolerant decoding — see the note on `AgentTurn`. A checkpoint is the record of what an
    // agent actually changed, so the trade is deliberate: only the fields that make it
    // meaningful (identity, track, commit contents) are required.
    private enum CodingKeys: String, CodingKey {
        case id, trackKey, agentSessionId, declaredIntent, changedFilePaths, fileChanges, commandsRun, provenance, gitCommitSHA, createdAt, verification
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        agentSessionId = try container.decodeIfPresent(UUID.self, forKey: .agentSessionId) ?? UUID()
        declaredIntent = try container.decodeIfPresent(String.self, forKey: .declaredIntent) ?? ""
        changedFilePaths = try container.decodeIfPresent([String].self, forKey: .changedFilePaths) ?? []
        fileChanges = try container.decodeIfPresent([CheckpointFileChange].self, forKey: .fileChanges) ?? []
        commandsRun = try container.decodeIfPresent([String].self, forKey: .commandsRun) ?? []
        provenance = try container.decodeIfPresent(AgentProvenance.self, forKey: .provenance)
            ?? AgentProvenance(providerId: "", modelId: "", instructionSourceSummary: "")
        gitCommitSHA = try container.decodeIfPresent(String.self, forKey: .gitCommitSHA)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        verification = try container.decodeIfPresent(CheckpointVerification.self, forKey: .verification)
    }
}
