import Foundation

/// The narrow slice of a window's Make stage an `AgentRunner` needs to read live editor state
/// and land an approved edit where a human is actually looking. Resolved fresh on every use via
/// `ProjectContext.bridge(forTrackKey:)`, never captured once — a runner now outlives any one
/// window (it survives a stage switch, a track switch, even the window that started it closing
/// while another window keeps the project open), so "the" Make tab to write into isn't a fixed
/// fact about a runner the way it was when Think lived inside one window's view controller.
/// `@unchecked Sendable`: every instance is built and consumed entirely on the main actor (it's
/// resolved fresh per-use from `ProjectContext.bridge(forTrackKey:)`, itself `@MainActor`), so
/// there's no actual cross-thread mutation risk — same reasoning `LSPManager` and
/// `ProviderRegistryStore` already use for similar single-threaded-in-practice types.
public struct WorkspaceBridge: @unchecked Sendable {
    public var liveBufferProvider: (URL) -> String?
    public var applyEditIntoOpenTab: (URL, String) -> Bool
    public var onRevealFileRequested: (URL) -> Void
    /// Types a `run_shell_command` proposal into the track's own real terminal once approved (or
    /// auto-run). Not gated on any window: terminals belong to the project
    /// (`TerminalSessionManager`), so a background track can run a command with nothing on screen.
    /// `TimeInterval` is how long the conversation waits for a result before saying "still
    /// running" — longer for a named task than for an ad-hoc command.
    public var runShellCommand: (String, TimeInterval, @escaping (String) -> Void) -> Void
    /// Interrupts whatever agent command is running for this track, if any — in the session that
    /// is running it, not whichever tab is selected.
    public var interruptShellCommand: () -> Void
    /// The agent's terminal has been moved outside the track's worktree: nothing auto-runs.
    public var agentTerminalIsOutsideWorktree: () -> Bool = { false }

    /// No window is currently both key and showing this track — reads fall back to disk, writes
    /// go straight to disk via `ProposedEditApplier`, and there's nowhere to jump to. Every one
    /// of these fallbacks was already the pre-extraction behavior for "Make doesn't have this
    /// file open," so a detached runner degrades to exactly that, never to a crash or a silently
    /// dropped edit. Only reached once the project itself is gone, so there is no terminal left.
    public static let none = WorkspaceBridge(
        liveBufferProvider: { _ in nil },
        applyEditIntoOpenTab: { _, _ in false },
        onRevealFileRequested: { _ in },
        runShellCommand: { _, _, completion in completion("The project was closed, so there's nowhere to run this command.") },
        interruptShellCommand: {}
    )

    public init(liveBufferProvider: @escaping (URL) -> String?, applyEditIntoOpenTab: @escaping (URL, String) -> Bool, onRevealFileRequested: @escaping (URL) -> Void, runShellCommand: @escaping (String, TimeInterval, @escaping (String) -> Void) -> Void, interruptShellCommand: @escaping () -> Void, agentTerminalIsOutsideWorktree: @escaping () -> Bool = { false }) {
        self.liveBufferProvider = liveBufferProvider
        self.applyEditIntoOpenTab = applyEditIntoOpenTab
        self.onRevealFileRequested = onRevealFileRequested
        self.runShellCommand = runShellCommand
        self.interruptShellCommand = interruptShellCommand
        self.agentTerminalIsOutsideWorktree = agentTerminalIsOutsideWorktree
    }
}

/// Conformed to by `ShellViewController` — one instance per window. `ProjectContext` keeps a
/// weak registry of these so `bridge(forTrackKey:)` can find whichever window, if any, is both
/// key and currently showing a given track. Without the `isKeyWindow` check, an agent running on
/// a track shown in a background window could apply its edit into a Make tab the user is
/// actively looking at in a *different*, focused window showing a different track — real data
/// loss once concurrent runners exist.
@MainActor
public protocol WorkspaceBridgeHost: AnyObject {
    var bridgeTrackKey: String? { get }
    var isKeyWindow: Bool { get }
    func liveBufferContent(for url: URL) -> String?
    func applyApprovedEdit(url: URL, newContent: String) -> Bool
    func revealAfterApply(_ url: URL)
}
