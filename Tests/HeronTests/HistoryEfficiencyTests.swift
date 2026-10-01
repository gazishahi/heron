import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, step 3: bounds on what enters the history (D2), the stale
/// sweep (D3), and compaction at 85% with Undo (D4).
final class ToolResultBoundsTests: XCTestCase {
    private func executor(_ files: [String: String]) throws -> (ToolExecutor, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heron-bounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        return (ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil }), root)
    }

    private func output(_ result: ToolExecutor.Result) -> String {
        guard case .completed(let output, _) = result else { return "" }
        return output
    }

    func testALongFileIsReadInPartAndSaysHowToGoOn() throws {
        let (tools, root) = try executor(["long.txt": (1...2_000).map { "line \($0)" }.joined(separator: "\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = output(tools.execute(name: "read_file", input: .object(["path": .string("long.txt")]), toolUseId: "a", scope: .ask))
        XCTAssertTrue(first.hasPrefix("1\tline 1\n"))
        XCTAssertTrue(first.contains("600\tline 600\n"))
        XCTAssertFalse(first.contains("601\tline 601"))
        XCTAssertTrue(first.hasSuffix("[lines 1–600 of 2000; read on with start_line 601]"))
        // An explicit range is honoured, and a short file comes back whole.
        let ranged = output(tools.execute(name: "read_file", input: .object(["path": .string("long.txt"), "start_line": .number(1990), "line_count": .number(20)]), toolUseId: "b", scope: .ask))
        XCTAssertTrue(ranged.hasSuffix("2000\tline 2000"))
    }

    func testLongLinesStopAtTheCeilingOnALineBoundary() throws {
        let line = String(repeating: "x", count: 200)
        let (tools, root) = try executor(["wide.txt": Array(repeating: line, count: 500).joined(separator: "\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let text = output(tools.execute(name: "read_file", input: .object(["path": .string("wide.txt")]), toolUseId: "a", scope: .ask))
        XCTAssertLessThanOrEqual(text.count, ToolExecutor.maxResultCharacters)
        let body = text.components(separatedBy: "\n").dropLast()
        XCTAssertTrue(body.allSatisfy { $0.hasSuffix(line) }, "whole lines only")
        XCTAssertTrue(text.contains("read on with start_line \(body.count + 1)"))
    }

    func testSearchClipsLinesAndTheWhole() throws {
        let minified = String(repeating: "var a=1;", count: 10_000)
        let (tools, root) = try executor(["min.js": minified])
        defer { try? FileManager.default.removeItem(at: root) }
        let text = output(tools.execute(name: "search_files", input: .object(["query": .string("var a")]), toolUseId: "a", scope: .ask))
        XCTAssertLessThan(text.count, ToolExecutor.maxSearchLineCharacters + 50)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testCommandOutputKeepsItsHeadAndTail() {
        let output = "$ swift build\n" + String(repeating: "compiling…\n", count: 5_000) + "error: it broke\n[exit code: 1]"
        let kept = ToolExecutor.headAndTail(output)
        XCTAssertLessThanOrEqual(kept.count, ToolExecutor.maxResultCharacters)
        XCTAssertTrue(kept.hasPrefix("$ swift build"))
        XCTAssertTrue(kept.hasSuffix("error: it broke\n[exit code: 1]"))
        XCTAssertTrue(kept.contains("characters elided"))
        XCTAssertEqual(ToolExecutor.headAndTail("short"), "short")
    }
}

final class HistorySweepTests: XCTestCase {
    private let big = String(repeating: "let value = 1\n", count: 100)

    private func read(_ id: String, _ path: String) -> [AgentTurn] {
        [AgentTurn(role: .assistant, content: [.toolUse(id: id, name: "read_file", input: .object(["path": .string(path)]))]),
         AgentTurn(role: .user, content: [.toolResult(toolUseId: id, content: big, isError: false)])]
    }

    private func typed(_ text: String) -> AgentTurn { AgentTurn(role: .user, content: [.text(text)]) }

    private func result(_ turns: [AgentTurn], _ id: String) -> String? {
        for turn in turns { for case .toolResult(let toolUseId, let content, _) in turn.content where toolUseId == id { return content } }
        return nil
    }

    func testAReadIsStubbedWhenReadAgainOrEditedSince() {
        var turns = [typed("look")] + read("r1", "a.swift") + read("r2", "b.swift")
        turns += [typed("again")] + read("r3", "a.swift")
        turns += [AgentTurn(role: .assistant, content: [.toolUse(id: "e1", name: "edit_file", input: .object(["path": .string("b.swift"), "old_string": .string("x"), "new_string": .string("y")]))]),
                  AgentTurn(role: .user, content: [.toolResult(toolUseId: "e1", content: "Applied.", isError: false)])]
        turns += [typed("now")]
        let swept = HistorySweep.sweep(turns)
        XCTAssertEqual(swept.stubbed, 2)
        XCTAssertTrue(result(swept.turns, "r1")?.contains("read again later") == true)
        XCTAssertTrue(result(swept.turns, "r2")?.contains("edited since") == true)
        XCTAssertEqual(result(swept.turns, "r3"), big, "the latest read stays")
        XCTAssertGreaterThan(swept.charactersSaved, 2_000)
        // A second sweep finds nothing: the history is left alone, and the cache with it.
        XCTAssertEqual(HistorySweep.sweep(swept.turns).stubbed, 0)
    }

    func testTheLastTypedMessageAndAfterAreNeverTouched() {
        let turns = [typed("look")] + read("r1", "a.swift") + read("r2", "a.swift")
        let swept = HistorySweep.sweep(turns)
        XCTAssertEqual(swept.stubbed, 0, "both reads belong to the message being worked on")
    }

    func testOldCommandOutputAndWriteBodiesAreStubbed() {
        let output = String(repeating: "Compiling…\n", count: 200) + "[exit code: 0]"
        var turns = [typed("build"),
                     AgentTurn(role: .assistant, content: [.toolUse(id: "c1", name: "run_shell_command", input: .object(["command": .string("swift build")])),
                                                          .toolUse(id: "w1", name: "write_file", input: .object(["path": .string("n.swift"), "content": .string(big)]))]),
                     AgentTurn(role: .user, content: [.toolResult(toolUseId: "c1", content: output, isError: false), .toolResult(toolUseId: "w1", content: "Applied.", isError: false)])]
        turns += [typed("two"), typed("three")]
        var swept = HistorySweep.sweep(turns)
        XCTAssertTrue(result(swept.turns, "c1")?.hasPrefix("[Side removed this output") == true)
        XCTAssertTrue(result(swept.turns, "c1")?.contains("exit code 0") == true)
        guard case .toolUse(_, _, .object(let input)) = swept.turns[1].content[1], case .string(let content)? = input["content"] else { return XCTFail() }
        XCTAssertTrue(content.hasPrefix("[Side removed"))
        // Output from the message before last is too recent.
        turns.removeLast()
        swept = HistorySweep.sweep(turns)
        XCTAssertEqual(result(swept.turns, "c1"), output)
    }
}

/// The runner: the sweep and compaction happen at a send, against a fake server.
@MainActor
final class HistoryCompactionTests: XCTestCase {
    nonisolated private static func isCompaction(_ body: [String: Any]) -> Bool {
        let last = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        return (last?.last?["text"] as? String)?.hasPrefix("Summarize this conversation") == true
    }

    func testPastTheThresholdASendCompactsFirstReusingTheCacheAndCanUndo() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, body in
            if Self.isCompaction(body) { return .text("SUMMARY: the parts were read.") }
            if index < 6 { return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(index).swift"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        // Six files of about 16,000 characters: about 24,000 tokens, over 85% of 26,000.
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual), contextWindow: 26_000)
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Read the parts."), .finishedTurn)
        let before = heron.turns
        XCTAssertGreaterThan(heron.runner.contextUsage().fraction, ContextBudget.autoCompactFraction)

        XCTAssertEqual(heron.send("What next?"), .finishedTurn)
        let bodies = try server.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let compactionIndex = try XCTUnwrap(bodies.firstIndex(where: Self.isCompaction))
        XCTAssertEqual(compactionIndex, 7, "after the first message's seven requests")
        // The same system prompt, tools and history as the conversation's last request: a cache read.
        let rendered = try server.requests.map(HeronRequestMeasurementTests.render)
        let (previous, compaction) = (rendered[compactionIndex - 1], rendered[compactionIndex])
        XCTAssertEqual(compaction.tools, previous.tools)
        XCTAssertEqual(compaction.system, previous.system)
        XCTAssertEqual(Array(compaction.messages.prefix(previous.messages.count)), previous.messages)

        let after = heron.turns
        XCTAssertTrue(after[0].isCompactionSummary)
        XCTAssertTrue(heron.runner.entries.contains { if case .compaction = $0.kind { return true } else { return false } })
        XCTAssertTrue(heron.runner.canUndoCompaction)

        XCTAssertTrue(heron.runner.undoCompaction())
        let restored = heron.turns
        XCTAssertEqual(restored.map { $0.id }, before.map { $0.id } + after.dropFirst().map { $0.id }, "the old conversation, then what was said since")
        XCTAssertFalse(heron.runner.canUndoCompaction)
    }

    func testPastHalfTheWindowASendSweepsOnce() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        // Every message reads Part0 and Part1, so the first message's reads are superseded.
        let server = try FakeModelServer { index, _ in
            switch index % 3 {
            case 0: return .tools([(name: "read_file", input: #"{"path": "Sources/Part0.swift"}"#)])
            case 1: return .tools([(name: "read_file", input: #"{"path": "Sources/Part1.swift"}"#)])
            default: return .text("Read.")
            }
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual), contextWindow: 30_000)
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Read two."), .finishedTurn)
        XCTAssertEqual(heron.send("Again."), .finishedTurn)
        XCTAssertGreaterThan(heron.runner.contextUsage().fraction, HistorySweep.thresholdFraction)
        XCTAssertEqual(heron.send("Once more."), .finishedTurn)
        let rendered = try server.requests.map(HeronRequestMeasurementTests.render)
        XCTAssertEqual(rendered.count, 9)
        // The third message's first request carries the stubs; the ones after it repeat it.
        XCTAssertEqual(rendered[6].messages.filter { $0.contains("[Side removed this earlier read") }.count, 2)
        XCTAssertEqual(Array(rendered[7].messages.prefix(rendered[6].messages.count)), rendered[6].messages)
        XCTAssertLessThan(server.requests[6].count, server.requests[5].count, "smaller than the request before the sweep")
        XCTAssertTrue(heron.runner.entries.contains { if case .meta(let text) = $0.kind { return text.hasPrefix("Cleared 2 stale results") } else { return false } })
    }
}
