import XCTest
@testable import Heron

/// The append-only conversation log. A persistence format's bugs are silent and permanent, so
/// these cover the round trip, the migration, and the partial-corruption cases specifically.
final class SessionLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessionlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var url: URL { directory.appendingPathComponent("s.jsonl") }

    private func session(turns: [AgentTurn]) -> AgentSession {
        AgentSession(
            id: UUID(), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5",
            turns: turns, createdAt: Date(timeIntervalSinceReferenceDate: 1),
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 2)
        )
    }

    private func textTurn(_ text: String, role: AgentMessage.Role = .user) -> AgentTurn {
        AgentTurn(role: role, content: [.text(text)])
    }

    func testRoundTripPreservesEverythingIncludingToolResultsAndImages() throws {
        let original = session(turns: [
            textTurn("hello"), textTurn("hi", role: .assistant),
            AgentTurn(role: .assistant, content: [.toolUse(id: "t1", name: "read_file", input: .object(["path": .string("a.swift")]))]),
            AgentTurn(role: .user, content: [.toolResult(toolUseId: "t1", content: "contents", isError: false)]),
            AgentTurn(role: .user, content: [.image(mediaType: "image/png", base64: "aGk="), .text("look")]),
        ])
        XCTAssertTrue(SessionLog.write(original, to: url))
        let reloaded = try XCTUnwrap(SessionLog.read(from: url))
        XCTAssertEqual(reloaded.id, original.id)
        XCTAssertEqual(reloaded.trackKey, "main")
        XCTAssertEqual(reloaded.providerId, "anthropic")
        XCTAssertEqual(reloaded.modelId, "claude-sonnet-5")
        XCTAssertEqual(reloaded.createdAt.timeIntervalSinceReferenceDate, 1, accuracy: 0.001)
        XCTAssertEqual(reloaded.turns.count, 5)
        guard case .image(let mediaType, _) = reloaded.turns[4].content.first else {
            return XCTFail("image block lost")
        }
        XCTAssertEqual(mediaType, "image/png")
    }

    func testAppendAddsOneTurnWithoutRewriting() throws {
        XCTAssertTrue(SessionLog.write(session(turns: [textTurn("first")]), to: url))
        let sizeBefore = try Data(contentsOf: url).count
        XCTAssertTrue(SessionLog.append(textTurn("second"), to: url))

        let reloaded = try XCTUnwrap(SessionLog.read(from: url))
        XCTAssertEqual(reloaded.turns.count, 2)
        // The whole point: the existing bytes are untouched and only the new record is written.
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(sizeBefore), try Data(contentsOf: url).prefix(sizeBefore))
        XCTAssertGreaterThan(after.count, sizeBefore)
    }

    func testAppendingToAMissingFileFailsRatherThanCreatingAHeaderlessOne() {
        // The caller falls back to a full write on false; silently creating a file with no
        // header would produce a session that can never be read back.
        XCTAssertFalse(SessionLog.append(textTurn("orphan"), to: url))
        XCTAssertNil(SessionLog.read(from: url))
    }

    func testATruncatedFinalLineCostsOnlyThatTurn() throws {
        // A crash mid-append leaves a partial record. Losing that one turn is recoverable;
        // losing the conversation is not — which is what the old all-or-nothing decode did,
        // after which the next append silently overwrote the file.
        var session = session(turns: [textTurn("one"), textTurn("two")])
        session.turns.append(textTurn("three"))
        XCTAssertTrue(SessionLog.write(session, to: url))
        var data = try Data(contentsOf: url)
        data = data.dropLast(12)  // chop the tail of the final record
        try data.write(to: url)

        let reloaded = try XCTUnwrap(SessionLog.read(from: url))
        XCTAssertEqual(reloaded.turns.count, 2)
        XCTAssertEqual(reloaded.trackKey, "main")
    }

    func testAnUnreadableHeaderIsReportedRatherThanGuessed() throws {
        try Data("not json\n".utf8).write(to: url)
        XCTAssertNil(SessionLog.read(from: url))
    }

}

/// Migration and the filename rules live in the store, not the log.
final class SessionStoreMigrationTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    func testBranchNamesThatUsedToCollideNowGetSeparateConversations() {
        // `feat/x` and `feat-x` both mapped to "feat-x.json" under the old slug rule, so two
        // real branches shared one conversation file and silently merged.
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        store.appendTurn(AgentTurn(role: .user, content: [.text("slashed")]), trackKey: "feat/x", providerId: "p", modelId: "m")
        store.appendTurn(AgentTurn(role: .user, content: [.text("dashed")]), trackKey: "feat-x", providerId: "p", modelId: "m")

        let reloaded = AgentSessionStore(stateDirectory: stateDirectory)
        let slashed = reloaded.session(forTrackKey: "feat/x")?.turns ?? []
        let dashed = reloaded.session(forTrackKey: "feat-x")?.turns ?? []
        XCTAssertEqual(slashed.count, 1)
        XCTAssertEqual(dashed.count, 1)
        func text(_ turns: [AgentTurn]) -> String? {
            guard case .text(let value)? = turns.first?.content.first else { return nil }
            return value
        }
        XCTAssertEqual(text(slashed), "slashed")
        XCTAssertEqual(text(dashed), "dashed")
    }

    func testCompactionStillReplacesEverything() {
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        for index in 0..<20 {
            store.appendTurn(AgentTurn(role: .user, content: [.text("turn \(index)")]), trackKey: "main", providerId: "p", modelId: "m")
        }
        store.replaceTurns([AgentTurn(role: .user, content: [.text("summary")])], trackKey: "main", providerId: "p", modelId: "m")

        let reloaded = AgentSessionStore(stateDirectory: stateDirectory)
        XCTAssertEqual(reloaded.session(forTrackKey: "main")?.turns.count, 1)
        // And appending after a compaction has to keep working — the file was fully rewritten.
        store.appendTurn(AgentTurn(role: .user, content: [.text("after")]), trackKey: "main", providerId: "p", modelId: "m")
        XCTAssertEqual(AgentSessionStore(stateDirectory: stateDirectory).session(forTrackKey: "main")?.turns.count, 2)
    }
}
