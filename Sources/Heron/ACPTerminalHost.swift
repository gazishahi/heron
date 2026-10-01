import Foundation

/// How an outside agent's process ended, as ACP reports it.
public struct ACPTerminalExit: Equatable, Sendable {
    public let exitCode: Int?
    public let signal: String?
    public init(exitCode: Int?, signal: String?) {
        self.exitCode = exitCode
        self.signal = signal
    }
    var json: [String: Any] {
        ["exitCode": exitCode.map { $0 as Any } ?? NSNull(), "signal": signal.map { $0 as Any } ?? NSNull()]
    }
}

/// What `terminal/output` returns.
public struct ACPTerminalOutput: Sendable {
    public let output: String
    public let truncated: Bool
    public let exit: ACPTerminalExit?
    public init(output: String, truncated: Bool, exit: ACPTerminalExit?) {
        self.output = output
        self.truncated = truncated
        self.exit = exit
    }
}

/// Where an outside agent's `terminal/*` requests run: the app's Run terminals
/// (`SIDE_RFC_BYO_HARNESS.md` step 3a). Each terminal is its own visible, interruptible tab
/// running the command directly — never typed into a shell the user is using, never queued
/// behind Heron's commands. Heron has no AppKit, so the app implements this.
@MainActor
public protocol ACPTerminalHost: AnyObject {
    /// Starts `command` in a new tab in the track's terminal list; `cwd` is already contained
    /// to the track's worktree. Returns the terminal's id.
    func createTerminal(trackKey: String, command: String, arguments: [String], environment: [String: String],
                        cwd: URL, outputByteLimit: Int, owner: UUID) throws -> String
    func output(of terminalId: String) -> ACPTerminalOutput?
    /// Calls back once the process has exited — immediately if it already has. False for an
    /// unknown id.
    func waitForExit(_ terminalId: String, completion: @escaping (ACPTerminalExit) -> Void) -> Bool
    /// Ends the process; the tab and its output stay until released.
    func kill(_ terminalId: String) -> Bool
    /// Ends the process if it still runs and closes its tab.
    func release(_ terminalId: String) -> Bool
    /// Every terminal `owner` created — Stop, cancel and teardown. `closeTabs` false keeps the
    /// output on screen (Stop); true closes them (the conversation ended).
    func endAll(owner: UUID, closeTabs: Bool)
}
