import Foundation

/// What a debugged program looks like right now, in a form the agent can read (the read-only
/// debug tool, SIDE_RFC_DEBUGGER.md, Q5): whether it's paused, why, where (the stack), with
/// what (the selected frame's locals and the watches), and what it printed last.
///
/// Published by Make's debugger, as `DiagnosticsSnapshot` is by its language servers: Heron
/// doesn't depend on Make, and reading never touches the debug adapter. The agent sees what the
/// person's debugger already fetched, so a question costs no requests and can't change the
/// program. Controlling it (breakpoints, stepping) would be a later step, with approval.
public final class DebugSnapshot: @unchecked Sendable {
    public static let shared = DebugSnapshot()

    public struct Frame: Equatable, Sendable {
        public let name: String
        /// Relative to the project when it's inside it; nil for a frame without source.
        public let path: String?
        public let line: Int
        public init(name: String, path: String?, line: Int) {
            self.name = name
            self.path = path
            self.line = line
        }
    }

    public struct Variable: Equatable, Sendable {
        public let name: String
        public let type: String?
        public let value: String
        /// One level of a structured value's members, when the debugger has them.
        public let children: [Variable]
        public init(name: String, type: String?, value: String, children: [Variable] = []) {
            self.name = name
            self.type = type
            self.value = value
            self.children = children
        }
    }

    public struct State: Equatable, Sendable {
        public enum Status: String, Sendable { case starting, running, paused, ended }
        public var program: String
        public var adapter: String
        public var status: Status
        /// Why it paused: "breakpoint", "step", "exception", "pause"…
        public var reason: String?
        /// For an exception: what was thrown, as the debugger describes it.
        public var exception: String?
        public var frames: [Frame] = []
        public var selectedFrame = 0
        public var locals: [Variable] = []
        public var watches: [(expression: String, value: String)] = []
        /// The console's last lines (the adapter's messages, a build's output).
        public var output = ""

        public init(program: String, adapter: String, status: Status) {
            self.program = program
            self.adapter = adapter
            self.status = status
        }

        public static func == (a: State, b: State) -> Bool {
            a.program == b.program && a.adapter == b.adapter && a.status == b.status && a.reason == b.reason && a.exception == b.exception
                && a.frames == b.frames && a.selectedFrame == b.selectedFrame && a.locals == b.locals && a.output == b.output
                && a.watches.map(\.expression) == b.watches.map(\.expression) && a.watches.map(\.value) == b.watches.map(\.value)
        }
    }

    private let lock = NSLock()
    private var byRoot: [String: State] = [:]

    public init() {}

    /// The project's session as it is now; nil when there's none.
    public func publish(_ state: State?, projectRoot: URL) {
        let key = projectRoot.standardizedFileURL.path
        lock.withLock { byRoot[key] = state }
    }

    public func state(projectRoot: URL) -> State? {
        let key = projectRoot.standardizedFileURL.path
        return lock.withLock { byRoot[key] }
    }

    /// Bounded, as every tool result is: a deep stack or a wide struct would cost the model more
    /// than it tells it.
    public static let maxFrames = 20
    public static let maxLocals = 30
    public static let maxChildren = 12
    public static let maxValue = 200
    public static let maxOutput = 1_500

    public func report(projectRoot: URL) -> String {
        guard let state = state(projectRoot: projectRoot) else {
            return "No debugging session in this project. The user starts one in Make (Debug \u{2192} Start Debugging); you can't start or control it."
        }
        var lines = ["Debugging \u{201C}\(state.program)\u{201D} with \(state.adapter): \(Self.describe(state))."]
        if let exception = state.exception, !exception.isEmpty { lines.append("Exception: " + Self.clip(exception, 600)) }
        if state.status == .paused {
            if state.frames.isEmpty {
                lines.append("No stack is known yet.")
            } else {
                lines += ["", "Stack (\(state.frames.count) frame\(state.frames.count == 1 ? "" : "s"), innermost first):"]
                for (index, frame) in state.frames.prefix(Self.maxFrames).enumerated() {
                    let place = frame.path.map { "\($0):\(frame.line)" } ?? "(no source)"
                    lines.append("  #\(index) \(frame.name)  \(place)\(index == state.selectedFrame ? "  \u{2190} selected" : "")")
                }
                if state.frames.count > Self.maxFrames { lines.append("  \u{2026} and \(state.frames.count - Self.maxFrames) more.") }
                lines += ["", state.locals.isEmpty ? "No locals in frame #\(state.selectedFrame)." : "Locals in frame #\(state.selectedFrame):"]
                for variable in state.locals.prefix(Self.maxLocals) {
                    lines.append("  " + Self.line(variable))
                    for child in variable.children.prefix(Self.maxChildren) { lines.append("    " + Self.line(child)) }
                    if variable.children.count > Self.maxChildren { lines.append("    \u{2026} \(variable.children.count - Self.maxChildren) more members") }
                }
                if state.locals.count > Self.maxLocals { lines.append("  \u{2026} and \(state.locals.count - Self.maxLocals) more.") }
            }
            if !state.watches.isEmpty {
                lines += ["", "Watches:"]
                for watch in state.watches { lines.append("  \(watch.expression) = \(Self.clip(watch.value, Self.maxValue))") }
            }
        } else if state.status == .running || state.status == .starting {
            lines.append("The stack and locals are known only while it's paused (at a breakpoint, an exception, or by the user).")
        }
        let output = state.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            lines += ["", "Console (last lines):", String(output.suffix(Self.maxOutput))]
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ state: State) -> String {
        switch state.status {
        case .starting: return "starting"
        case .running: return "running"
        case .ended: return "ended"
        case .paused:
            switch state.reason {
            case "breakpoint"?: return "paused at a breakpoint"
            case "step"?: return "paused after a step"
            case "exception"?: return "paused on an exception"
            case "entry"?: return "paused at entry"
            default: return "paused"
            }
        }
    }

    private static func line(_ variable: Variable) -> String {
        "\(variable.name)\(variable.type.map { ": \($0)" } ?? "") = \(clip(variable.value, maxValue))"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "\u{2026}" : single
    }
}
