import Foundation

/// Stale content out of the history, in one sweep (SIDE_RFC_HERON_EFFICIENCY.md, D3 and the
/// owner's answer to Q1).
///
/// Every request re-sends the whole conversation, so a file read ten turns ago and read again
/// since is paid for on every request after both. The sweep replaces what's been superseded
/// with a one-line stub that says what was there and how to get it back:
/// - a `read_file` result when the same read happened later, or the file was edited or written
///   since (what it showed is no longer the file);
/// - command and task output from a few typed messages back;
/// - the body of an older `write_file`, and the long strings of an older `edit_file`: the file
///   holds them, and a read shows it as it is now.
///
/// It runs when the context passes half the window, and all at once: a changed turn ends the
/// cached prefix there, so one sweep rebuilds the cache once rather than every turn. It never
/// touches the last typed message or anything after it, which the model is still working from.
public enum HistorySweep {
    /// The share of the window at which a send sweeps first.
    public static let thresholdFraction = 0.5
    /// Command output with this many typed messages since, the one being sent included, is stubbed.
    public static let commandAgeInMessages = 3
    /// Anything shorter stays: a stub costs about as much.
    public static let minimumStubbedCharacters = 600

    public struct Result {
        public var turns: [AgentTurn]
        public var stubbed: Int
        public var charactersSaved: Int
    }

    static let stubPrefix = "[Side removed "

    public static func sweep(_ turns: [AgentTurn]) -> Result {
        // Typed messages: user turns that aren't tool results.
        let typed = turns.indices.filter { index in
            turns[index].role == .user && !turns[index].content.contains { if case .toolResult = $0 { return true } else { return false } }
        }
        guard let lastTyped = typed.last else { return Result(turns: turns, stubbed: 0, charactersSaved: 0) }
        // Command output before this turn index is old enough. The sweep runs as a message is
        // sent, so that message is one of the typed messages after it.
        let after = commandAgeInMessages - 1
        let commandCutoff = typed.count >= after ? typed[typed.count - after] : 0

        // Every tool call, by id, with where it happened.
        struct Call { let name: String; let input: JSONValue; let turn: Int }
        var calls: [String: Call] = [:]
        var failed: Set<String> = []
        for (index, turn) in turns.enumerated() {
            for block in turn.content {
                switch block {
                case .toolUse(let id, let name, let input): calls[id] = Call(name: name, input: input, turn: index)
                case .toolResult(let id, _, let isError): if isError { failed.insert(id) }
                default: break
                }
            }
        }
        func path(_ input: JSONValue) -> String? {
            guard case .object(let object) = input, case .string(let path)? = object["path"] else { return nil }
            return (path as NSString).standardizingPath
        }
        func readKey(_ input: JSONValue) -> String {
            guard case .object(let object) = input else { return "" }
            return ["path", "start_line", "line_count"].map { key -> String in
                switch object[key] {
                case .string(let value)?: return key == "path" ? (value as NSString).standardizingPath : value
                case .number(let value)?: return String(Int(value))
                default: return ""
                }
            }.joined(separator: "\u{1F}")
        }
        // For each path, the last turn that changed it and the last that read it (by read key).
        var lastChange: [String: Int] = [:]
        var lastRead: [String: Int] = [:]
        for (id, call) in calls where !failed.contains(id) {
            switch call.name {
            case "edit_file", "write_file":
                if let path = path(call.input) { lastChange[path] = max(lastChange[path] ?? -1, call.turn) }
            case "read_file":
                lastRead[readKey(call.input)] = max(lastRead[readKey(call.input)] ?? -1, call.turn)
            default: break
            }
        }

        var result = turns
        var stubbed = 0
        var saved = 0
        for index in turns.indices where index < lastTyped {
            var content = turns[index].content
            var changed = false
            for (position, block) in content.enumerated() {
                switch block {
                case .toolResult(let id, let text, let isError):
                    guard !isError, text.count >= minimumStubbedCharacters, !text.hasPrefix(stubPrefix), let call = calls[id] else { continue }
                    var stub: String?
                    switch call.name {
                    case "read_file":
                        guard let path = path(call.input) else { continue }
                        if (lastChange[path] ?? -1) > call.turn {
                            stub = "\(stubPrefix)this earlier read of \(path): the file has been edited since. Read it again for what it holds now.]"
                        } else if (lastRead[readKey(call.input)] ?? -1) > call.turn {
                            stub = "\(stubPrefix)this earlier read of \(path): it was read again later in the conversation.]"
                        }
                    case "run_shell_command", "run_task":
                        guard index < commandCutoff else { continue }
                        let exit = exitLine(text).map { ", \($0)" } ?? ""
                        stub = "\(stubPrefix)this output to save context: \(text.count) characters\(exit). Run it again if you need it.]"
                    default:
                        continue
                    }
                    if let stub {
                        content[position] = .toolResult(toolUseId: id, content: stub, isError: false)
                        saved += text.count - stub.count
                        stubbed += 1
                        changed = true
                    }
                case .toolUse(let id, let name, let input):
                    guard name == "write_file" || name == "edit_file", case .object(var object) = input else { continue }
                    var inputChanged = false
                    for key in ["content", "old_string", "new_string"] {
                        guard case .string(let value)? = object[key], value.count >= minimumStubbedCharacters, !value.hasPrefix(stubPrefix) else { continue }
                        let stub = "\(stubPrefix)\(value.count) characters here to save context; read the file for what it holds now.]"
                        object[key] = .string(stub)
                        saved += value.count - stub.count
                        inputChanged = true
                    }
                    if inputChanged {
                        content[position] = .toolUse(id: id, name: name, input: .object(object))
                        stubbed += 1
                        changed = true
                    }
                default:
                    continue
                }
            }
            if changed { result[index].content = content }
        }
        return Result(turns: result, stubbed: stubbed, charactersSaved: saved)
    }

    /// "exit code: 1", from the line the terminal appends when it knows.
    private static func exitLine(_ output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).reversed().prefix(4) {
            guard let range = line.range(of: "[exit code: "), let close = line[range.upperBound...].firstIndex(of: "]") else { continue }
            return "exit code " + line[range.upperBound..<close]
        }
        return nil
    }
}
