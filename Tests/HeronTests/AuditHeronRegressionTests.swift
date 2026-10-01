import XCTest
@testable import Heron

@MainActor
/// The 2026-09-30 audit's Heron findings, as the tests that reproduced them (HER-1 to HER-4,
/// H3). Each failed on the code the audit read.
final class AuditHeronRegressionTests: XCTestCase {
    nonisolated private static func isCompaction(_ body: [String: Any]) -> Bool {
        let last = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        return (last?.last?["text"] as? String)?.hasPrefix("Summarize this conversation") == true
    }

    private func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if done() { return }
        }
    }

    // HER: command output bypasses the 16,000 ceiling (toolResult returns `content`, not the bounded text).
    func testCommandOutputEntersHistoryUnbounded() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            if index == 0 { return .tools([(name: "run_shell_command", input: #"{"command": "make test"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let registry = ProviderRegistryStore(storeURL: state.appendingPathComponent("providers.json"))
        var anthropic = try XCTUnwrap(registry.provider(for: "anthropic"))
        anthropic.baseURL = server.baseURL
        registry.addOrUpdate(anthropic)
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil { setenv("ANTHROPIC_API_KEY", "fake", 1) }
        let usage = UsageStore(storeURL: state.appendingPathComponent("usage.json"))
        let store = AgentSessionStore(stateDirectory: state.appendingPathComponent("sessions"))
        let big = (0..<5_000).map { "line \($0) of output" }.joined(separator: "\n") // ~95,000 chars
        let bridge = WorkspaceBridge(
            liveBufferProvider: { _ in nil }, applyEditIntoOpenTab: { _, _ in false }, onRevealFileRequested: { _ in },
            runShellCommand: { _, _, completion in completion(String(big.suffix(60_000))) }, interruptShellCommand: {}
        )
        let root = project
        let runner = AgentRunner(trackKey: "", sessionStore: store, projectPath: project.path,
                                 bridgeProvider: { bridge }, rootProvider: { root },
                                 modeProvider: { AgentMode(scope: .build, autonomy: .manual) },
                                 modelSelectionProvider: { ("anthropic", "claude-sonnet-5", .standard) },
                                 providerRegistry: registry, usageStore: usage)
        runner.send("Run the tests.")
        spin(20) {
            if runner.phase == .awaitingApproval {
                for entry in runner.entries {
                    if case .commandProposal(let p) = entry.kind, p.resolution == nil { runner.resolve(proposalId: entry.id, decision: .apply) }
                }
            }
            return runner.phase == .finishedTurn
        }
        XCTAssertEqual(runner.phase, .finishedTurn)
        let results = store.session(forTrackKey: "")!.turns.flatMap(\.content).compactMap { b -> String? in
            if case .toolResult(_, let c, _) = b { return c } else { return nil }
        }
        XCTAssertLessThanOrEqual(results.first?.count ?? 0, ToolExecutor.maxResultCharacters, "bounded to the ceiling")
    }

    // HER: manual compaction leaves the measured count stale; the next send compacts the summary again.
    func testManualCompactionThenSendRecompactsAndLosesUndo() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, body in
            if Self.isCompaction(body) { return .text("SUMMARY: the parts were read.") }
            if index < 6 { return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(index).swift"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual), contextWindow: 26_000)
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Read the parts."), .finishedTurn)
        let before = heron.turns
        var done = false
        heron.runner.compact(automatic: false) { _ in done = true }
        spin(20) { done }
        XCTAssertTrue(heron.turns.first?.isCompactionSummary == true)
        XCTAssertLessThan(heron.runner.contextUsage().fraction, 0.5, "the gauge should describe the compacted conversation")
        XCTAssertEqual(heron.send("What next?"), .finishedTurn)
        let bodies = try server.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let compactions = bodies.filter(Self.isCompaction).count
        XCTAssertEqual(compactions, 1, "one compaction, the manual one")
        XCTAssertTrue(heron.runner.undoCompaction())
        XCTAssertEqual(Array(heron.turns.prefix(before.count)).map(\.id), before.map(\.id), "Undo brings back the original conversation")
    }

    // HER: teardown while tools run doesn't stop the loop.
    func testTeardownDuringRunningToolsStillSendsNextRequest() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            if index < 3 { return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(index).swift"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }
        let runner = heron.runner
        var tornDown = false
        runner.addObserver { [weak runner] event in
            guard case .phaseChanged = event, let runner, runner.phase == .runningTools, !tornDown else { return }
            tornDown = true
            runner.teardown()
        }
        runner.send("Read.")
        spin(4)
        XCTAssertEqual(server.requests.count, 1, "nothing sent after teardown")
    }

    // HER: Stop during an automatic compaction is ignored; the message is sent anyway.
    func testStopDuringAutoCompactionStillSends() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, body in
            if Self.isCompaction(body) { return .text("SUMMARY: the parts were read.") }
            if index < 6 { return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(index).swift"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual), contextWindow: 26_000)
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Read the parts."), .finishedTurn)
        let countBefore = server.requests.count
        let runner = heron.runner
        var stopped = false
        runner.addObserver { [weak runner] event in
            guard case .appended(let i) = event, let runner, !stopped, runner.entries.indices.contains(i),
                  case .meta(let text) = runner.entries[i].kind, text.hasPrefix("The conversation is near") else { return }
            stopped = true
            runner.stop()
        }
        runner.send("What next?")
        spin(6)
        XCTAssertTrue(stopped)
        let since = try server.requests.dropFirst(countBefore).map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertTrue(since.allSatisfy(Self.isCompaction), "nothing but the compaction was sent")
        XCTAssertFalse(runner.phase.isBusy)
        XCTAssertTrue(heron.turns.contains { $0.content.contains { if case .text("What next?") = $0 { return true } else { return false } } },
                      "the message is kept, unsent")
    }

    // UX-4: after an automatic compaction is undone, the next send sends the whole conversation.
    func testTheSendAfterAnUndoDoesntCompactAgain() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, body in
            if Self.isCompaction(body) { return .text("SUMMARY: the parts were read.") }
            if index < 6 { return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(index).swift"}"#)]) }
            return .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual), contextWindow: 26_000)
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Read the parts."), .finishedTurn)
        XCTAssertEqual(heron.send("What next?"), .finishedTurn)  // compacts first
        let compactions = { try server.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }.filter(Self.isCompaction).count }
        XCTAssertEqual(try compactions(), 1)
        XCTAssertTrue(heron.runner.undoCompaction())
        XCTAssertEqual(heron.send("And then?"), .finishedTurn)
        XCTAssertEqual(try compactions(), 1, "the send after Undo carried the whole conversation")
        XCTAssertFalse(heron.turns.contains(where: \.isCompactionSummary))
    }

    // H5: a tool call cut off at the output limit, or by an overload error, isn't run, and
    // nothing more is sent.
    func testAnIncompleteToolCallIsNotRunAndNothingMoreIsSent() throws {
        for overloaded in [false, true] {
            let project = try HeronRequestMeasurementTests.fixtureProject()
            defer { try? FileManager.default.removeItem(at: project) }
            let server = try FakeModelServer { _, _ in
                .cutToolCall(name: "write_file", partialInput: #"{"path": "Sources/New.swift", "content": "struct New {\n  // a long "#, overloaded: overloaded)
            }
            defer { server.stop() }
            let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                          mode: AgentMode(scope: .build, autonomy: .full))
            defer { heron.cleanUp() }
            heron.runner.send("Write it.")
            spin(5) { !heron.runner.phase.isBusy && server.requests.count >= 1 }
            spin(1)
            XCTAssertEqual(server.requests.count, 1, "nothing sent after the cut (overloaded: \(overloaded))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Sources/New.swift").path))
            XCTAssertFalse(heron.turns.contains { $0.content.contains { if case .toolUse = $0 { return true } else { return false } } },
                           "no tool_use without its result")
            XCTAssertNotEqual(heron.runner.phase, .finishedTurn, "not reported as done")
            if !overloaded {
                XCTAssertTrue(heron.runner.entries.contains { if case .failure(let text) = $0.kind { return text.contains("output limit") } else { return false } })
            }
        }
    }
}
