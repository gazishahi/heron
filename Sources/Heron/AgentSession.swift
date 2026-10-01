import Foundation

public struct AgentTurn: Codable, Identifiable {
    public let id: UUID
    public let role: AgentMessage.Role
    public var content: [AgentContentBlock]
    public let createdAt: Date
    /// Context Side adds for the model alone (what the `@`-mentions resolved to, what a branch
    /// left applied), sent after `content` on every request and never shown in the bubble.
    /// Resolved once, when the message is sent, and stored with it: a note recomputed per
    /// request moved and changed the bytes of the history, and a changed byte ends the cached
    /// prefix there. It says what was true when the person sent the message.
    public let notes: [String]?

    public init(role: AgentMessage.Role, content: [AgentContentBlock], notes: [String]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.notes = notes?.isEmpty == true ? nil : notes
    }

    /// The summary a compaction left in the conversation's place.
    public var isCompactionSummary: Bool {
        guard role == .user, case .text(let text)? = content.first else { return false }
        return text.hasPrefix(ContextBudget.summaryMarker)
    }

    /// The turn as the model reads it.
    public var message: AgentMessage {
        AgentMessage(role: role, content: content + (notes ?? []).map { .text($0) })
    }

    // Tolerant decoding, for the same reason `Track` has it: a persisted turn written by an
    // older build is missing whatever field the newer build added, and synthesized Codable
    // treats that as a hard failure — which would take the whole conversation file down with
    // it. Identity and content are the only fields worth refusing to load without.
    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(AgentMessage.Role.self, forKey: .role)
        content = try container.decode([AgentContentBlock].self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        notes = try container.decodeIfPresent([String].self, forKey: .notes)
    }
}

/// One conversation with an agent, tied to one track. Keyed by branch name (`""` for "no
/// active track"), the same per-track convention Make's file memory and Run's terminal
/// sessions already use — a string key, not a Track UUID, because a session must be able to
/// exist for a project with no tracks at all.
public struct AgentSession: Codable, Identifiable {
    public let id: UUID
    public let trackKey: String
    public var providerId: String
    public var modelId: String
    public var turns: [AgentTurn]
    /// The provider's own reported input-token count for the most recent request.
    ///
    /// Persisted because it is *measured* — the alternative is the character-count estimate,
    /// which is arithmetic. Keeping it only in memory meant the context gauge silently dropped
    /// to the lower estimate after every relaunch, so the same conversation read 5% and then 3%
    /// with nothing having changed. Same failure as the elapsed-time header: a measured value
    /// that isn't saved, falling back to something wrong instead of saying it doesn't know.
    public var lastReportedInputTokens: Int?
    public let createdAt: Date
    public var lastActiveAt: Date

    public init(trackKey: String, providerId: String, modelId: String) {
        self.id = UUID()
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.turns = []
        self.lastReportedInputTokens = nil
        self.createdAt = Date()
        self.lastActiveAt = Date()
    }

    /// Memberwise — used by `SessionLog`, which reconstructs a session from a header line plus
    /// separately-decoded turns rather than decoding one whole object.
    public init(id: UUID, trackKey: String, providerId: String, modelId: String, turns: [AgentTurn], createdAt: Date, lastActiveAt: Date, lastReportedInputTokens: Int? = nil) {
        self.id = id
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.turns = turns
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.lastReportedInputTokens = lastReportedInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackKey, providerId, modelId, turns, createdAt, lastActiveAt, lastReportedInputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackKey = try container.decode(String.self, forKey: .trackKey)
        turns = try container.decodeIfPresent([AgentTurn].self, forKey: .turns) ?? []
        // Provider/model are metadata about who answered, not part of the conversation — a file
        // missing them should still open, with the active provider filling in on the next turn.
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? createdAt
        lastReportedInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastReportedInputTokens)
    }
}
