import Foundation

/// One renderable unit of a Think conversation, owned by `AgentRunner` — never an `NSView`, so
/// more than one observer (Think today; Tracks and a stage badge once B1 lands) can render the
/// same run without inheriting AppKit assumptions. Headers ("You" / "Assistant") aren't a case
/// here — they're implied by `.userText`/`.assistantText` and drawn by whoever renders this, not
/// baked into the data.
public struct RunTranscriptEntry: Identifiable {
    public let id = UUID()
    /// When this entry actually happened — feeds the "Worked for Ns" header on grouped tool
    /// activity.
    ///
    /// Explicitly settable, and that is the whole point: it used to default to `Date()` at
    /// construction, and `hydrateFromSession` constructs fresh entries when a conversation is
    /// reloaded. So every historical entry was stamped with the moment of the *reload*, and a
    /// group that really took seven seconds reported one — the number was truthful only inside
    /// the session that produced it. Rehydration now passes the persisted turn's own timestamp.
    public let createdAt: Date
    /// The persisted `AgentTurn` this entry was rendered from, when there is one.
    ///
    /// Needed because `id` identifies the *entry*, not the conversation turn, and editing a
    /// message has to name a turn in the session. Only set for turns a human authored — the one
    /// thing that can be edited — so an assistant block has no handle by which to be rewritten.
    public let sourceTurnId: UUID?
    public var kind: Kind

    public init(kind: Kind, createdAt: Date = Date(), sourceTurnId: UUID? = nil) {
        self.kind = kind
        self.createdAt = createdAt
        self.sourceTurnId = sourceTurnId
    }

    public enum Kind {
        case meta(String)
        case userText(String)
        /// An image the user attached, held as encoded bytes so any observer can render it.
        case userImage(Data)
        /// Mutated in place while the model streams — each delta fires `.updated`, not a fresh
        /// `.appended`, so the transcript grows one paragraph, not one block per token.
        case assistantText(String)
        /// The model's own reasoning, streamed in place like `assistantText`. Rendered inside the
        /// activity group rather than as a bubble: it is *how* the answer was reached, not the
        /// answer, and a group that says "Worked for 34s" with nothing inside it was the gap this
        /// fills. Never persisted — see `AgentStreamEvent.thinkingDelta`.
        case thinking(String)
        case toolCall(name: String, summary: String)
        case toolResult(text: String, isError: Bool)
        case failure(String)
        case proposal(ProposalPresentation)
        case commandProposal(CommandPresentation)
        /// "✓ Checkpoint (sha): intent" — a meta line that knows which checkpoint it names, so
        /// the transcript can open that checkpoint's files and diff in place (Direction 02 §5.1).
        case checkpoint(id: UUID, text: String)
        /// "Conversation compacted…": a meta line with Undo while the runner can undo it.
        case compaction(String)
        /// An outside agent asking before it acts (ACP `session/request_permission`): the agent's
        /// own options become the card's buttons (`SIDE_RFC_BYO_HARNESS.md` D3).
        case permissionRequest(PermissionPresentation)
    }
}

/// An outside agent's permission prompt and, once answered, which option was chosen.
public struct PermissionPresentation {
    public struct Option: Equatable {
        public enum Kind: String { case allowOnce = "allow_once", allowAlways = "allow_always", rejectOnce = "reject_once", rejectAlways = "reject_always" }
        public let id: String
        public let name: String
        public let kind: Kind?
        public init(id: String, name: String, kind: Kind?) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }
    /// What the agent wants to do, in its own words (the tool call's title).
    public let title: String
    public let options: [Option]
    /// The option picked; nil while waiting. "cancelled" when the turn was stopped first.
    public var chosenOptionName: String?

    public init(title: String, options: [Option], chosenOptionName: String? = nil) {
        self.title = title
        self.options = options
        self.chosenOptionName = chosenOptionName
    }
}

/// What the transcript needs to render (and re-render) a `run_shell_command` proposal —
/// `ProposalPresentation`'s sibling for commands rather than edits. Separate types because the
/// two resolve completely differently (a diff-and-apply vs. typing into Run's terminal and
/// waiting for a sentinel), not because the UI shape needs to differ much.
public struct CommandPresentation {
    public let command: ProposedCommand
    public var resolution: Resolution?

    public enum Resolution {
        case executed(output: String)
        case rejected

        public var label: (text: String, color: ProposalPresentation.ResolutionColor) {
            switch self {
            case .executed: return ("Ran", .success)
            case .rejected: return ("Rejected", .neutral)
            }
        }
    }

    public init(command: ProposedCommand, resolution: Resolution?) {
        self.command = command
        self.resolution = resolution
    }
}

/// What the transcript needs to render (and re-render) a proposed edit, independent of the
/// `NSView` that displays it. Resolution lives here, not just in the view — a detach/reattach
/// (stage switch, track switch and back) rebuilds an already-resolved card showing its outcome,
/// not a fresh Apply/Reject asking the user to decide a second time. Not persisted across a
/// relaunch — once a session is reloaded from disk, a resolved proposal renders as a plain
/// toolCall/toolResult pair, same as any other completed tool exchange.
public struct ProposalPresentation {
    /// `var`, not `let` — resolution strips `edit`'s full file content (see
    /// `ProposedEdit.stripContent()`) once it's no longer needed, so this entry doesn't hold a
    /// duplicate old-and-new copy of the file for the rest of the session.
    public var edit: ProposedEdit
    /// `var` because a streaming preview's body is replaced as the model writes, and then once
    /// more by the real unified diff when the call completes.
    public var diffText: String
    public var resolution: Resolution?
    /// True while the model is still writing this tool call's arguments. The card renders, but
    /// offers no decision: what's on screen is a preview of text arriving, not a validated
    /// proposal, and Apply would be asking the user to approve half a sentence.
    public var isStreaming: Bool = false

    public enum Resolution {
        case applied
        case rejected
        case staleBase
        case writeFailed(String)
        /// The call finished but the executor refused it — `old_string` matched nothing, the
        /// content was identical, the path wasn't writable. The preview card stays as the record
        /// of what was attempted rather than vanishing and leaving the transcript unexplained.
        case notProposed(String)

        public init(_ outcome: ProposedEditOutcome) {
            switch outcome {
            case .applied: self = .applied
            case .rejected: self = .rejected
            case .staleBase: self = .staleBase
            case .writeFailed(let message): self = .writeFailed(message)
            }
        }

        public var label: (text: String, color: ResolutionColor) {
            switch self {
            case .applied: return ("Applied", .success)
            case .rejected: return ("Rejected", .neutral)
            case .staleBase: return ("File changed, not applied", .warning)
            case .writeFailed(let message): return ("Failed: \(message)", .failure)
            case .notProposed(let message): return (message, .warning)
            }
        }
    }

    /// Semantic, not `NSColor` — this type has no AppKit dependency so it can be shared with a
    /// future non-AppKit observer (Tracks' dashboard) without pulling one in.
    public enum ResolutionColor { case success, neutral, warning, failure }

    public init(edit: ProposedEdit, diffText: String, resolution: Resolution?, isStreaming: Bool = false) {
        self.edit = edit
        self.diffText = diffText
        self.resolution = resolution
        self.isStreaming = isStreaming
    }
}

/// What decided a proposal — the human clicked one of two buttons, nothing else.
public enum ProposalDecision { case apply, reject }

/// Coarse state of one run, for anything that wants to show activity without inspecting
/// `entries` — the Think send button, the Tracks dashboard, and the stage badge all derive from
/// this rather than each re-deriving their own notion of "busy."
public enum AgentRunPhase: Equatable {
    case idle
    case streaming
    case runningTools
    case awaitingApproval
    /// Stopped short of a clean turn end and needs a human decision to continue — never set by
    /// a transport error or a user-initiated Stop, only by the two conditions in `BlockedReason`.
    case blocked(BlockedReason)
    /// A turn just ended cleanly (the model stopped asking for tools, nothing pending). Distinct
    /// from `.idle` — which is only ever "never started" — so `AgentActivity` can tell "finished,
    /// not yet looked at" from "finished, already seen" via `hasUnseenCompletion`, the same
    /// mechanic `RunSession.hasUnseenOutput` uses for background Run tabs.
    case finishedTurn

    public enum BlockedReason: Equatable {
        /// Hit `AgentRunner`'s round-trip cap — the model kept asking for tools with no end in
        /// sight. Send another message to continue.
        case roundTripLimit
        /// No stream event for `AgentRunner`'s stall window — a hung connection is otherwise
        /// indistinguishable from a working agent.
        case stalled
        /// This month's estimated spend has reached the configured budget. Distinct from the
        /// other two because the fix isn't "send again," it's "change the budget" — see
        /// `UsageBudget`.
        case budgetReached
        /// The turn ended without an answer: a provider error, a dropped or truncated stream, a
        /// missing key. The failure is in the transcript; this makes it *reachable* — a failed run
        /// used to finish as `.idle`, so a background rate-limit produced no chip, no badge, and
        /// no notification, and the user found out by wondering why nothing had happened.
        /// (2026-09-01 audit, product/IA.)
        case failed
    }

    /// Send is only meaningful when nothing is actively running — every other phase either has
    /// a network call in flight, tool execution in flight, or a decision pending that a new
    /// message would jump the queue of.
    public var isBusy: Bool {
        switch self {
        case .streaming, .runningTools, .awaitingApproval: return true
        case .idle, .blocked, .finishedTurn: return false
        }
    }
}

/// What Tracks (and eventually a stage badge) actually renders — coarser than `AgentRunPhase`,
/// and the only thing either of those need to know about a runner. Deliberately not derived from
/// `TrackStatus`: activity is machine-owned and ephemeral, status is human-owned lifecycle — see
/// `AgentRunner.activity`.
public enum AgentActivity: Equatable {
    case none
    case working
    case needsYou
    /// A run that ended in an error. Routed everywhere `needsYou` is — pinned, badged, notified —
    /// but named separately so the ledger can say "Failed" rather than "Needs you": the
    /// constitution's "what failed" is its own question.
    case failed
    case doneUnread
    case doneSeen

    /// Everything that should reach the user: an approval waiting, a blocked run, a failure.
    public var wantsAttention: Bool { self == .needsYou || self == .failed }

    public init(phase: AgentRunPhase, hasUnseenCompletion: Bool) {
        switch phase {
        case .idle:
            self = .none
        case .streaming, .runningTools:
            self = .working
        case .blocked(.failed):
            self = .failed
        case .awaitingApproval, .blocked:
            self = .needsYou
        case .finishedTurn:
            self = hasUnseenCompletion ? .doneUnread : .doneSeen
        }
    }
}

/// What changed since the last notification, so an observer can apply a minimal update instead
/// of re-rendering the whole transcript on every token.
public enum AgentRunEvent {
    /// The transcript was rebuilt wholesale (attaching to a runner for the first time) — the
    /// observer should discard whatever it had and render `entries` from scratch.
    case reset
    case appended(Int)
    case updated(Int)
    case phaseChanged
}
