import XCTest
@testable import Heron

final class UsageBudgetTests: XCTestCase {
    private var storeURL: URL!
    private var originalLimit: Double?

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-tests-\(UUID().uuidString)")
            .appendingPathComponent("usage.json")
        originalLimit = UsageBudget.monthlyLimitUSD
    }

    override func tearDown() {
        UsageBudget.monthlyLimitUSD = originalLimit
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeStore() -> UsageStore { UsageStore(storeURL: storeURL) }

    /// $3 of Sonnet input per million tokens — the cheapest way to write "spend this much."
    /// Rounded, not truncated: truncating $5 to 1,666,666 tokens spends $4.999998, and two of
    /// those land a hair under a threshold the test means to cross.
    private func spend(_ dollars: Double, in store: UsageStore, at date: Date = Date()) {
        // Sonnet 5's input: $2 a million tokens (the published price).
        let tokens = Int((dollars / 2 * 1_000_000).rounded(.up))
        store.record(
            projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5",
            usage: TokenUsage(inputTokens: tokens, outputTokens: 0, cachedInputTokens: nil), now: date
        )
    }

    func testNoBudgetNeverBlocks() {
        // No limit means unlimited however much was spent. A literal $0 ceiling would block every
        // request forever, which is never what someone typing in that field meant — it reads as
        // no budget too.
        UsageBudget.monthlyLimitUSD = nil
        let store = makeStore()
        spend(500, in: store)
        XCTAssertEqual(UsageBudget.status(store: store), .unlimited)
        XCTAssertFalse(UsageBudget.status(store: store).blocksSending)

        UsageBudget.monthlyLimitUSD = 0
        XCTAssertNil(UsageBudget.monthlyLimitUSD)
        XCTAssertEqual(UsageBudget.status(store: store), .unlimited)
    }

    func testWarnsAtEightyPercentAndBlocksAtTheLimit() {
        UsageBudget.monthlyLimitUSD = 10
        let store = makeStore()

        spend(5, in: store)
        guard case .withinBudget = UsageBudget.status(store: store) else {
            return XCTFail("half spent should be within budget")
        }

        spend(3, in: store) // 8 of 10
        guard case .approaching = UsageBudget.status(store: store) else {
            return XCTFail("80% should warn")
        }
        XCTAssertFalse(UsageBudget.status(store: store).blocksSending, "a warning must not block")

        spend(2, in: store) // 10 of 10
        guard case .exceeded = UsageBudget.status(store: store) else {
            return XCTFail("reaching the limit should block")
        }
        XCTAssertTrue(UsageBudget.status(store: store).blocksSending)
    }

    func testMonthlyScoping() throws {
        // Last month's spend does not count against this month, but it is still real money, so
        // all-time totals keep it — and the two months sit in separate rows that the all-time
        // per-model view rolls back together.
        UsageBudget.monthlyLimitUSD = 10
        let store = makeStore()
        let now = Date()
        let lastMonth = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -1, to: now))

        spend(50, in: store, at: lastMonth)

        XCTAssertEqual(UsageBudget.status(store: store, now: now), .withinBudget(spent: 0, limit: 10))
        XCTAssertEqual(store.estimatedCostThisMonth(now: now).total, 0, accuracy: 0.0001)
        XCTAssertEqual(store.estimatedCost().total, 50, accuracy: 0.01)

        spend(3, in: store, at: now)
        XCTAssertEqual(store.records.count, 2, "same track and model, different months — two rows")
        XCTAssertEqual(store.totalsByModel().count, 1)
        XCTAssertEqual(store.estimatedCostThisMonth(now: now).total, 3, accuracy: 0.01)
    }

    func testPeriodKeyIsCalendarMonthInLocalTime() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(UsageRecord.periodKey(for: date), "2026-03")
    }

    func testRecordsWrittenBeforeBudgetsExistedStillLoad() throws {
        // The tolerant-decoding contract, exercised on the field this feature added: an old row
        // has no periodKey, so it can't be attributed to a month — it counts toward all-time
        // totals and is left out of monthly ones rather than inflating the current month.
        let legacy = #"[{"projectPath":"/a","trackKey":"main","providerId":"anthropic","modelId":"claude-sonnet-5","totals":{"inputTokens":1000000,"outputTokens":0,"cachedInputTokens":0,"requestCount":1},"lastUsedAt":"2026-01-15T00:00:00Z"}]"#
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: storeURL)

        let store = makeStore()
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].periodKey, "")
        XCTAssertEqual(store.estimatedCost().total, 2, accuracy: 0.01)
        XCTAssertEqual(store.estimatedCostThisMonth().total, 0, accuracy: 0.0001)
    }
}
