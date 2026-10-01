import Foundation

/// A shell command an agent has asked to run but that has **not** executed — the `run_shell_command`
/// analog of `ProposedEdit`. Requires approval by default (see `Track.autoRunCommands` for the
/// per-track opt-out); either way, execution always happens by typing into the track's own real,
/// visible Run session, never a hidden `Process` — see `WorkspaceBridge.runShellCommand`.
public struct ProposedCommand: Identifiable {
    public let id: UUID
    public let toolUseId: String
    public let command: String
    /// Classified once, at proposal time, from the command text — see `CommandRiskClassifier`.
    /// A `.destructive` command never auto-runs even on a track with `autoRunCommands` on; see
    /// `AgentRunner.handleToolOutcomes`.
    public let riskLevel: CommandRiskLevel
    /// Set when this command came from `run_task` — the name of the task it is. Carried through
    /// so the result can be recorded as verification on the checkpoint, and so the approval card
    /// can say "Run test" rather than showing a command line the user has to parse.
    public let taskName: String?
    /// What approving this actually does. A fetch rides the same card, approval, and autonomy
    /// rules as a command because it has the same shape of consequence: a URL is an outbound
    /// channel, and an agent that has read the user's files can encode them into one.
    public let kind: Kind

    public enum Kind: Equatable {
        case shell
        case fetch(URL)
        /// A coordinator creating a subtrack (multi-agent RFC, M1): same card, same approval.
        case spawn(SubtrackRequest)
        /// A coordinator merging one of its subtracks into itself (M2). `fullMayApply`: the
        /// subtrack's newest checkpoint passed verification and it shares no file with a sibling,
        /// so Full autonomy may do it without a card.
        case promote(track: String, fullMayApply: Bool)
    }

    public init(toolUseId: String, command: String, taskName: String? = nil) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = command
        self.taskName = taskName
        self.kind = .shell
        self.riskLevel = CommandRiskClassifier.classify(command)
    }

    public init(toolUseId: String, fetching url: URL) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = "GET \(url.absoluteString)"
        self.taskName = nil
        self.kind = .fetch(url)
        self.riskLevel = .normal
    }

    public init(toolUseId: String, spawning request: SubtrackRequest, agentName: String) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = "Create subtrack \u{201C}\(request.intent)\u{201D} on \(agentName)"
        self.taskName = nil
        self.kind = .spawn(request)
        self.riskLevel = .normal
    }

    public init(toolUseId: String, promoting track: String, intent: String, fullMayApply: Bool) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = "Promote subtrack \u{201C}\(intent)\u{201D} into this track"
        self.taskName = nil
        self.kind = .promote(track: track, fullMayApply: fullMayApply)
        self.riskLevel = .normal
    }

    public var promotion: (track: String, fullMayApply: Bool)? {
        if case .promote(let track, let fullMayApply) = kind { return (track, fullMayApply) } else { return nil }
    }

    public var fetchURL: URL? { if case .fetch(let url) = kind { return url } else { return nil } }
    public var spawnRequest: SubtrackRequest? { if case .spawn(let request) = kind { return request } else { return nil } }
}

/// How long a conversation waits on a command before saying "still running" — the command
/// itself keeps going in the visible terminal either way.
public enum CommandTimeout {
    /// An ad-hoc command.
    public static let command: TimeInterval = 30
    /// A *task* — the project's own build or test command, which the user asked for by name and
    /// can watch. Thirty seconds is shorter than most real test suites, so the short default meant
    /// verification never landed for the projects it was built for (2026-09-01 audit, H14a).
    public static let task: TimeInterval = 600
}
