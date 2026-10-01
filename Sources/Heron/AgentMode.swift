import Foundation

/// What the agent is allowed to *attempt* — the tool half of a track's mode.
///
/// Enforced by which tool specs the model is even shown, not by asking it nicely: a model that
/// never receives `write_file` cannot propose a write, so "Ask" is a real boundary rather than a
/// prompt it might talk itself out of.
public enum AgentToolScope: String, Codable, CaseIterable, Sendable {
    /// Read-only. Answer questions about the project; no edits, no commands.
    case ask
    /// Read-only too, but asked for a plan rather than an answer — the difference is what the
    /// agent is *for*, which is why it's a separate scope and not a prompt someone retypes.
    case plan
    /// Everything: reads, edits, and commands. The default, and what Side did before modes.
    case build

    public static let `default` = AgentToolScope.build

    public var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .plan: return "Plan"
        case .build: return "Build"
        }
    }

    /// Reading is always allowed; this is about what else is.
    public var allowsWrites: Bool { self == .build }
    public var allowsCommands: Bool { self == .build }

    /// Appended to the system prompt. Scope is enforced by tool availability above — this only
    /// tells the agent *why* its tools look the way they do, so it explains itself instead of
    /// repeatedly trying a tool that isn't there.
    public var systemPromptAddendum: String? {
        switch self {
        case .ask:
            return """
                This track is in Ask mode: you have read-only tools. Answer the question from what \
                you can read. If the work needs edits or commands, say what you would do and why, \
                and tell the user to switch this track to Build mode.
                """
        case .plan:
            return """
                This track is in Plan mode: you have read-only tools. Produce a concrete plan (the \
                files involved, the order of the changes, and what could go wrong) rather than \
                prose about the problem. Do not ask to edit anything; the user will switch the \
                track to Build mode when the plan is right.
                """
        case .build:
            return nil
        }
    }
}

/// How much the agent may do *without asking* — the approval half of a track's mode.
///
/// Replaces the old single `Track.autoRunCommands` bool, which conflated "I trust ordinary
/// commands here" with "stop asking me about everything."
public enum AgentAutonomy: String, Codable, CaseIterable, Sendable {
    /// Every edit and every command waits for a human. The default, and the constitution's
    /// "agents propose; people promote" in its strictest form.
    case manual
    /// Ordinary read-only commands run on their own; edits still wait. This is exactly what
    /// `autoRunCommands == true` used to mean, which is what it migrates to.
    case guarded
    /// Edits apply and ordinary commands run without asking. Anything the risk classifier won't
    /// vouch for still stops — see the note on `autoAppliesEdits`.
    case full

    public static let `default` = AgentAutonomy.manual

    public var displayName: String {
        switch self {
        case .manual: return "Manual: approve everything"
        case .guarded: return "Guarded: auto-run safe commands"
        case .full: return "Full: auto-apply edits too"
        }
    }

    public var shortLabel: String {
        switch self {
        case .manual: return "manual"
        case .guarded: return "guarded"
        case .full: return "full"
        }
    }

    /// Whether an allowlisted command may skip its approval card. The allowlist itself
    /// (`CommandAutoRunPolicy`) stays a hard floor at *every* level including `.full`: a mode is
    /// a statement about routine work, never permission to `rm -rf` unattended.
    public var autoRunsAllowlistedCommands: Bool { self != .manual }

    /// Whether a proposed file edit applies without a click.
    ///
    /// Only at `.full`, and worth being explicit about: this is the one setting in Side that
    /// steps past "agents propose; people promote." It exists because the alternative — clicking
    /// through forty mechanical renames — is how people end up approving without reading, which
    /// is worse. Every applied edit is still a checkpoint, so it remains reviewable and
    /// revertable after the fact rather than invisible.
    public var autoAppliesEdits: Bool { self == .full }
}

/// A track's mode: the two axes together, plus the migration from what came before.
public struct AgentMode: Equatable, Sendable {
    public var scope: AgentToolScope
    public var autonomy: AgentAutonomy

    public static let `default` = AgentMode(scope: .default, autonomy: .default)

    /// One line for a header that already carries provider, model, and effort.
    public var shortLabel: String { "\(scope.displayName) · \(autonomy.shortLabel)" }

    /// Autonomy above `.manual` is meaningless in a read-only scope — there is nothing to
    /// auto-approve. Reported rather than silently corrected so the UI can explain itself.
    public var autonomyIsMeaningful: Bool { scope == .build }

    /// What a track with no stored mode should be, given the old bool it may still carry.
    /// `autoRunCommands == true` meant precisely "auto-run ordinary commands, keep asking about
    /// edits" — which is `.guarded`, so nobody's existing setting silently changes meaning.
    public static func migrating(autoRunCommands: Bool) -> AgentMode {
        AgentMode(scope: .default, autonomy: autoRunCommands ? .guarded : .manual)
    }

    public init(scope: AgentToolScope, autonomy: AgentAutonomy) {
        self.scope = scope
        self.autonomy = autonomy
    }
}
