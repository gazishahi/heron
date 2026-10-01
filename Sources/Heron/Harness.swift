import Foundation

/// One of an outside agent's own settings — its model, effort, permission mode — as the agent
/// reports it (ACP `configOptions`, or its older `modes` / `models`). Heron has none: its model,
/// effort, scope and autonomy are Side's own controls (RFC D6).
public struct HarnessOption: Equatable, Sendable, Codable {
    public struct Choice: Equatable, Sendable, Codable {
        public let value: String
        public let name: String
        public let detail: String?
        /// The agent's own classification (`_meta.kind`: "standard", "plan", "auto_review",
        /// "full_access"…) — how Side knows a mode lets the agent act without asking.
        public let kind: String?
        public init(value: String, name: String, detail: String? = nil, kind: String? = nil) {
            self.value = value
            self.name = name
            self.detail = detail
            self.kind = kind
        }
    }
    public enum Category: String, Sendable, Codable { case model, effort, mode, other }
    public let id: String
    public let name: String
    public let category: Category
    public var current: String
    public let choices: [Choice]

    public init(id: String, name: String, category: Category, current: String, choices: [Choice]) {
        self.id = id
        self.name = name
        self.category = category
        self.current = current
        self.choices = choices
    }

    public var currentChoice: Choice? { choices.first { $0.value == current } }
    /// The current choice lets the agent change files without asking Side (it auto-approves,
    /// or accepts edits): its edits land directly and are reviewable afterwards (RFC D1).
    public var actsWithoutAsking: Bool {
        guard category == .mode, let choice = currentChoice else { return false }
        return ["auto_review", "full_access"].contains(choice.kind ?? "") || choice.value == "acceptEdits"
    }
}

/// The engine behind one track's conversation — what Think, the track pill, Tracks, Run's task
/// row and inline instruct talk to. Heron's `AgentRunner` is one; an Agent Client Protocol
/// client for outside agents (Claude Code, Codex, Gemini CLI, Pi…) will be another
/// (`SIDE_RFC_BYO_HARNESS.md`). Nothing above this protocol knows which one it's driving.
///
/// The surface is the one the app already used on `AgentRunner`, lifted as-is: a renderable
/// transcript, a coarse phase, a multicast of changes, and the handful of actions a person can
/// take. Where a harness can't do something (compact a conversation, run a task on its own),
/// it says so through the same members rather than through a second API.
@MainActor
public protocol Harness: AnyObject {
    /// The track this conversation belongs to — its branch name.
    var trackKey: String { get }
    /// The outside agent's name ("Claude Code"), nil for Heron — the session pill says which
    /// engine a track is on.
    var harnessName: String? { get }

    // MARK: What's on screen

    /// The renderable transcript, never an `NSView`.
    var entries: [RunTranscriptEntry] { get }
    var phase: AgentRunPhase { get }
    /// `phase` projected for anything that shows status without understanding the loop.
    var activity: AgentActivity { get }
    /// When the harness last started waiting on a person, for oldest-first ordering.
    var needsYouSince: Date? { get }
    var hasCommandAwaitingApproval: Bool { get }
    /// Per-file line counts applied in this conversation — Think's changed-files pill.
    var appliedEditCounts: [(path: String, added: Int, removed: Int)] { get }
    var archivedConversations: [ArchivedConversation] { get }
    func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status)

    // MARK: Readiness

    /// A message could be sent right now (a model is configured and reachable).
    var isReadyToSend: Bool { get }
    var notReadyReason: String { get }

    // MARK: Observation

    @discardableResult
    func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID
    func removeObserver(_ token: UUID)

    // MARK: Actions

    func send(_ text: String, attachments: [AgentImageAttachment])
    func stop()
    func resolve(proposalId: UUID, decision: ProposalDecision)
    /// Answers a `.permissionRequest` entry with one of its options; nil cancels it.
    func answerPermission(proposalId: UUID, optionId: String?)
    func acknowledgeCompletion()
    func editableMessage(turnId: UUID) -> (text: String, attachments: [AgentImageAttachment])?
    func editAndResend(turnId: UUID, text: String, attachments: [AgentImageAttachment])
    func compact(completion: @escaping (Result<Void, Error>) -> Void)
    /// Whether the last compaction can be undone (Heron's; an outside agent compacts its own).
    var canUndoCompaction: Bool { get }
    @discardableResult func undoCompaction() -> Bool
    func startNewConversation()
    func openArchivedConversation(id: UUID) -> Bool

    // MARK: The agent's own settings (outside agents; empty for Heron)

    /// Model, effort, mode… as the agent reports them. Empty until a session is open.
    var agentOptions: [HarnessOption] { get }
    /// The account the agent says it's running on ("Claude Team", "Anthropic API key").
    var accountLabel: String? { get }
    func setAgentOption(id: String, value: String)
    /// Opens the agent's session ahead of the first message, so its settings can be shown and
    /// changed before anything is sent. No-op for Heron.
    func prepareSession()

    // MARK: Lifecycle

    /// The project is closing or the track was deleted: end whatever is in flight, for good.
    func teardown()

    // MARK: Run's task row

    var runningUserTaskName: String? { get }
    var pendingUserTaskProposalId: UUID? { get }
    /// Proposes a project task as a command card; nil when the harness is busy.
    @discardableResult
    func proposeUserTask(_ task: ProjectTask) -> UUID?
}

extension Harness {
    public func send(_ text: String) { send(text, attachments: []) }
    public func editAndResend(turnId: UUID, text: String) { editAndResend(turnId: turnId, text: text, attachments: []) }
}

extension AgentRunner: Harness {
    public func compact(completion: @escaping (Result<Void, Error>) -> Void) { compact(automatic: false, completion: completion) }
    public var harnessName: String? { nil }
    public var agentOptions: [HarnessOption] { [] }
    public var accountLabel: String? { nil }
    public func setAgentOption(id: String, value: String) {}
    public func prepareSession() {}
    /// Heron asks through proposal cards, never permission prompts.
    public func answerPermission(proposalId: UUID, optionId: String?) {}
}
