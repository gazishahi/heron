import XCTest
@testable import Heron

final class HistoryRetentionTests: XCTestCase {
    private var stateDirectory: URL!
    private var originalRetention: HistoryRetention!

    override func setUp() {
        super.setUp()
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("retention-tests-\(UUID().uuidString)")
        originalRetention = HistoryRetention.current
    }

    override func tearDown() {
        HistoryRetention.current = originalRetention
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    func testCutoffDateFollowsTheSetting() throws {
        // Forever has no cutoff at all; a window is the configured number of days back.
        HistoryRetention.current = .forever
        XCTAssertNil(HistoryRetention.current.cutoffDate())

        HistoryRetention.current = .thirtyDays
        let now = Date()
        let cutoff = try XCTUnwrap(HistoryRetention.current.cutoffDate(now: now))
        let days = Calendar.current.dateComponents([.day], from: cutoff, to: now).day
        XCTAssertEqual(days, 30)
    }

    func testExpiredConversationsAreRemovedOnNextOpen() throws {
        HistoryRetention.current = .forever
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        store.appendTurn(AgentTurn(role: .user, content: [.text("old")]), trackKey: "stale", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendTurn(AgentTurn(role: .user, content: [.text("new")]), trackKey: "fresh", providerId: "anthropic", modelId: "claude-sonnet-5")

        // Age the stale track's file and index entry by rewriting the index with an old date —
        // the same thing the passage of time would do.
        let indexURL = stateDirectory.appendingPathComponent("think/index.json")
        JSONStore.flushPendingWrites()  // the index is written a moment after it changes
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: indexURL)) as? [String: Any])
        var entries = try XCTUnwrap(raw["payload"] as? [[String: Any]])
        let longAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60 * 24 * 120))
        for position in entries.indices where entries[position]["trackKey"] as? String == "stale" {
            entries[position]["lastActiveAt"] = longAgo
        }
        raw["payload"] = entries
        try JSONSerialization.data(withJSONObject: raw).write(to: indexURL)

        HistoryRetention.current = .thirtyDays
        let reopened = AgentSessionStore(stateDirectory: stateDirectory)

        XCTAssertNil(reopened.session(forTrackKey: "stale"), "a conversation past the retention window should be gone")
        XCTAssertEqual(reopened.session(forTrackKey: "fresh")?.turns.count, 1, "a recent conversation must survive")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("think/sessions/stale.json").path),
            "expiry has to delete the file, not just drop the index entry — the tool output is the point"
        )
    }

    func testDeleteAllRemovesConversationsButKeepsCheckpoints() {
        HistoryRetention.current = .forever
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        store.appendTurn(AgentTurn(role: .user, content: [.text("hello")]), trackKey: "feature", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendCheckpoint(Checkpoint(
            trackKey: "feature", agentSessionId: UUID(), declaredIntent: "tidy up",
            changedFilePaths: ["a.swift"], commandsRun: [],
            provenance: AgentProvenance(providerId: "anthropic", modelId: "claude-sonnet-5", instructionSourceSummary: ""),
            gitCommitSHA: "abc123"
        ))

        store.deleteAllSessions()

        XCTAssertNil(store.session(forTrackKey: "feature"))
        // Checkpoints point at real commits and record what an agent actually changed — losing
        // them to a history purge would delete the audit trail, not the transcript.
        XCTAssertEqual(store.checkpoints(forTrackKey: "feature").count, 1)
    }
}
