import XCTest
@testable import Heron

/// Review's summary: the newest thing an agent said on a track, read from the end of its record.
final class AgentAccountTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLastRecordReadsFromTheEndAcrossWindows() throws {
        let url = directory.appendingPathComponent("log.jsonl")
        var records: [OutsideSessionLog.Record] = [.init(kind: .header, agentId: "claude")]
        for turn in 0..<200 {
            records.append(.init(kind: .user, text: "question \(turn)"))
            records.append(.init(kind: .assistant, text: "answer \(turn) " + String(repeating: "x", count: 900)))
            records.append(.init(kind: .tool, text: "read_file", detail: String(repeating: "y", count: 2000)))
        }
        XCTAssertTrue(OutsideSessionLog.append(records, to: url))
        // A small window, so the answer is found only after reading back past a cut line.
        let last = OutsideSessionLog.lastRecord(of: .assistant, in: url, window: 1500)
        XCTAssertEqual(last?.text.hasPrefix("answer 199 "), true)
        XCTAssertEqual(OutsideSessionLog.lastRecord(of: .user, in: url, window: 700)?.text, "question 199")
        XCTAssertNil(OutsideSessionLog.lastRecord(of: .failure, in: url))
        XCTAssertEqual(OutsideSessionLog.agentId(in: url), "claude")
    }

    private func checkpoint(track: String, provider: String) -> Checkpoint {
        Checkpoint(trackKey: track, agentSessionId: UUID(), declaredIntent: "x", changedFilePaths: [], commandsRun: [],
                   provenance: AgentProvenance(providerId: provider, modelId: "m", instructionSourceSummary: ""), gitCommitSHA: "abc")
    }

    func testAnOutsideAgentsAccountIsWhatItSaidInTheCheckpointsTurn() throws {
        let store = AgentSessionStore(stateDirectory: directory)
        let made = checkpoint(track: "feature", provider: "acp:codex")
        let url = store.outsideLogURL(trackKey: "feature", agentId: "codex")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        OutsideSessionLog.append([
            .init(kind: .header, agentId: "codex"),
            .init(kind: .user, text: "Add the index"),
            .init(kind: .assistant, text: "Looking."),
            .init(kind: .tool, text: "edit"),
            .init(kind: .assistant, text: "Added LineIndex and its tests."),
            .init(kind: .checkpoint, text: "1", checkpointId: made.id),
            .init(kind: .user, text: "thanks"),
            .init(kind: .assistant, text: "Anything else you'd like to look at?"),
        ], to: url)
        let account = store.agentAccount(for: made)
        XCTAssertEqual(account?.text, "Added LineIndex and its tests.", "not the later question")
        XCTAssertEqual(account?.agentId, "codex")
        XCTAssertNil(store.agentAccount(for: checkpoint(track: "feature", provider: "acp:codex")), "a checkpoint with no mark has no account")
    }

    func testHeronsAccountIsTheAnswerBeforeTheCheckpoint() {
        let store = AgentSessionStore(stateDirectory: directory)
        _ = store.appendTurn(AgentTurn(role: .user, content: [.text("Rename it")]), trackKey: "feature", providerId: "p", modelId: "m")
        _ = store.appendTurn(AgentTurn(role: .assistant, content: [.text("Renamed compute to calculate.")]), trackKey: "feature", providerId: "p", modelId: "m")
        let made = checkpoint(track: "feature", provider: "anthropic")
        Thread.sleep(forTimeInterval: 1.2)
        _ = store.appendTurn(AgentTurn(role: .user, content: [.text("hi")]), trackKey: "feature", providerId: "p", modelId: "m")
        _ = store.appendTurn(AgentTurn(role: .assistant, content: [.text("What next?")]), trackKey: "feature", providerId: "p", modelId: "m")
        XCTAssertEqual(store.agentAccount(for: made)?.text, "Renamed compute to calculate.")
        XCTAssertNil(store.agentAccount(for: made)?.agentId)
    }
}
