import XCTest
@testable import Heron

final class ContextBudgetTests: XCTestCase {

    private func turn(_ role: AgentMessage.Role, text: String) -> AgentTurn {
        AgentTurn(role: role, content: [.text(text)])
    }

    private func toolResultTurn(characters: Int) -> AgentTurn {
        AgentTurn(role: .user, content: [
            .toolResult(toolUseId: "t", content: String(repeating: "x", count: characters), isError: false)
        ])
    }

    // MARK: - Estimation

    func testTheEstimateCountsProseToolResultsAndImages() {
        XCTAssertEqual(ContextBudget.estimatedTokens(in: []), 0)
        let short = [turn(.user, text: "hello")]
        let long = short + [turn(.assistant, text: String(repeating: "a reply ", count: 500))]
        XCTAssertGreaterThan(ContextBudget.estimatedTokens(in: long), ContextBudget.estimatedTokens(in: short))
        // A single read_file can be tens of thousands of characters — an estimate that only
        // counted prose would report a nearly-empty window on a conversation about to fail.
        let withResult = [turn(.user, text: "read it"), toolResultTurn(characters: 40_000)]
        XCTAssertGreaterThan(ContextBudget.estimatedTokens(in: withResult), 9_000)
        // Images are priced by pixels server-side; the estimate charges a flat figure per image
        // so the gauge moves when screenshots pile up.
        let withImage = [AgentTurn(role: .user, content: [.image(mediaType: "image/png", base64: "aGk=")])]
        XCTAssertGreaterThan(ContextBudget.estimatedTokens(in: withImage), 1_000)
    }

    // MARK: - Thresholds

    func testStatusCrossesAtTheDocumentedFractionsAndOnlyTheUpperOnesSuggestCompaction() {
        // The fraction is clamped so the gauge can't exceed full, whatever the provider reports.
        let window = 100_000
        let cases: [(fraction: Double, status: ContextBudget.Status, suggestsCompaction: Bool, gauge: Double)] = [
            (0.5, .comfortable, false, 0.5),
            (0.69, .comfortable, false, 0.69),
            (0.70, .approaching, true, 0.70),
            (0.89, .approaching, true, 0.89),
            (0.90, .critical, true, 0.90),
            (1.5, .critical, true, 1),
        ]
        for c in cases {
            let usage = ContextBudget.usage(turns: [], windowTokens: window, lastReportedInputTokens: Int(Double(window) * c.fraction))
            XCTAssertEqual(usage.status, c.status, "at \(c.fraction)")
            XCTAssertEqual(usage.status.shouldSuggestCompaction, c.suggestsCompaction, "at \(c.fraction)")
            XCTAssertEqual(usage.fraction, c.gauge, accuracy: 0.0001, "at \(c.fraction)")
        }
    }

    // MARK: - Measured vs estimated

    func testAReportedCountBeatsALowerEstimate() {
        // The provider's own number is measured; the estimate is arithmetic on character counts.
        // Prompt-cache and system-prompt overhead mean the real figure is usually higher.
        let turns = [turn(.user, text: "hi")]
        let usage = ContextBudget.usage(turns: turns, windowTokens: 200_000, lastReportedInputTokens: 50_000)
        XCTAssertEqual(usage.usedTokens, 50_000)
    }

    func testTurnsAddedSinceTheLastRequestArentInvisible() {
        // The measured count describes the *previous* request. A huge tool result arriving after
        // it has to move the gauge, or the warning comes too late to be useful.
        let turns = [turn(.user, text: "read it"), toolResultTurn(characters: 800_000)]
        let usage = ContextBudget.usage(turns: turns, windowTokens: 200_000, lastReportedInputTokens: 1_000)
        XCTAssertGreaterThan(usage.usedTokens, 1_000)
        XCTAssertEqual(usage.status, .critical)
    }

    func testAnUnknownWindowDoesNotProduceAFalseWarning() {
        // A BYOK provider can report 0; claiming "critical" on no information would train people
        // to ignore the gauge.
        let usage = ContextBudget.usage(turns: [turn(.user, text: "hello")], windowTokens: 0, lastReportedInputTokens: nil)
        XCTAssertEqual(usage.status, .comfortable)
        XCTAssertEqual(usage.fraction, 0)
    }


    func testTheMeasuredCountAndItsClearingSurviveAReload() throws {
        // The bug: this count is the provider's *measured* figure and lived only in memory, so
        // after a relaunch the gauge fell back to the character-count estimate and the same
        // conversation reported 5% and then 3% with nothing having changed. Clearing it must
        // persist too: compaction replaces the conversation the count measured, so a stale
        // figure would overstate a freshly-compacted session forever.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AgentSessionStore(stateDirectory: directory)
        store.appendTurn(AgentTurn(role: .user, content: [.text("hi")]), trackKey: "main", providerId: "p", modelId: "m")
        store.recordReportedInputTokens(48_000, forTrackKey: "main")

        let reloaded = AgentSessionStore(stateDirectory: directory)
        XCTAssertEqual(reloaded.session(forTrackKey: "main")?.lastReportedInputTokens, 48_000)

        // And it must actually move the gauge, not merely be stored.
        let turns = reloaded.session(forTrackKey: "main")?.turns ?? []
        let usage = ContextBudget.usage(
            turns: turns, windowTokens: 200_000,
            lastReportedInputTokens: reloaded.session(forTrackKey: "main")?.lastReportedInputTokens
        )
        XCTAssertEqual(usage.usedTokens, 48_000)

        store.recordReportedInputTokens(nil, forTrackKey: "main")
        XCTAssertNil(AgentSessionStore(stateDirectory: directory).session(forTrackKey: "main")?.lastReportedInputTokens)
    }

    // MARK: - The summary contract

    func testCompactionInstructionAsksForWhatAContinuationNeeds() {
        let instruction = ContextBudget.compactionInstruction.lowercased()
        for expected in ["decisions", "paths", "unfinished"] {
            XCTAssertTrue(instruction.contains(expected), "missing \(expected)")
        }
        // Re-inlining file contents into the summary would defeat the point of compacting.
        XCTAssertTrue(instruction.contains("leave out"), instruction)
    }

    func testSummaryTurnSaysDetailIsGone() {
        let text = ContextBudget.summaryTurnText("Fixed the off-by-one in sumRange.")
        XCTAssertTrue(text.contains("Fixed the off-by-one in sumRange."))
        // The next turn has to know it's reading a summary, not the conversation — otherwise the
        // agent asserts things it no longer actually knows.
        XCTAssertTrue(text.lowercased().contains("compacted"))
        XCTAssertTrue(text.lowercased().contains("re-read"))
    }
}

/// Compaction replaces a conversation wholesale. These cover the store-level contract it relies
/// on — anything less and a half-written replacement could leave a conversation the API rejects.
final class ConversationCompactionTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    func testCompactedConversationHasNoDanglingToolUse() {
        let store = AgentSessionStore(stateDirectory: stateDirectory)
        // A conversation caught mid-tool-call: the assistant asked, nothing answered yet.
        store.appendTurn(AgentTurn(role: .user, content: [.text("read it")]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendTurn(AgentTurn(role: .assistant, content: [
            .toolUse(id: "tool1", name: "read_file", input: .object(["path": .string("a.swift")]))
        ]), trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        let summary = AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText("read a.swift"))])
        let session = store.replaceTurns([summary], trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5")

        // Replacing *everything* (rather than keeping a tail of recent turns) is what guarantees
        // this: an unanswered tool_use is a protocol violation the API rejects outright, and a
        // tail-preserving compaction could easily cut between a call and its result.
        XCTAssertNil(AgentSessionStore.repairingDanglingToolUses(session), "compaction left a tool_use needing repair")
        XCTAssertEqual(session.turns.count, 1)
    }
}
