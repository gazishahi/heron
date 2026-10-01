import XCTest
@testable import Heron

final class UsageStoreTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("usage.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeStore() -> UsageStore { UsageStore(storeURL: storeURL) }

    private func usage(input: Int, output: Int, cached: Int? = nil) -> TokenUsage {
        TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached)
    }

    func testRepeatedRecordsAccumulateIntoOneRowAndSurviveReload() {
        let store = makeStore()
        store.record(projectPath: "/p", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 100, output: 20))
        store.record(projectPath: "/p", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 50, output: 5, cached: 400))

        XCTAssertEqual(store.records.count, 1)
        let totals = store.totals(projectPath: "/p", trackKey: "main")
        XCTAssertEqual(totals.inputTokens, 150)
        XCTAssertEqual(totals.outputTokens, 25)
        XCTAssertEqual(totals.cachedInputTokens, 400)
        // Every streamed turn is billed, so a second report is a second request even on the
        // same track and model.
        XCTAssertEqual(totals.requestCount, 2)

        let reloaded = makeStore().totals(projectPath: "/p", trackKey: "main")
        XCTAssertEqual(reloaded.inputTokens, 150)
        XCTAssertEqual(reloaded.outputTokens, 25)
        XCTAssertEqual(reloaded.cachedInputTokens, 400)
        XCTAssertEqual(reloaded.requestCount, 2)
    }

    func testUsageIsSeparatedByTrackProjectAndModel() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 10, output: 1))
        store.record(projectPath: "/a", trackKey: "feature", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 20, output: 2))
        store.record(projectPath: "/b", trackKey: "main", providerId: "anthropic", modelId: "claude-opus-5", usage: usage(input: 40, output: 4))

        XCTAssertEqual(store.records.count, 3)
        XCTAssertEqual(store.totals(projectPath: "/a", trackKey: "main").inputTokens, 10)
        XCTAssertEqual(store.totals(projectPath: "/a", trackKey: "feature").inputTokens, 20)
        XCTAssertEqual(store.totalsByModel().count, 2)
        XCTAssertEqual(store.totalsByProject().count, 2)
        XCTAssertEqual(store.grandTotal().inputTokens, 70)
    }

    func testRemovingATrackDropsOnlyThatTracksUsage() {
        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 10, output: 1))
        store.record(projectPath: "/a", trackKey: "gone", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 99, output: 9))

        store.removeUsage(projectPath: "/a", trackKey: "gone")

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.grandTotal().inputTokens, 10)
    }

    func testChangeObserverFiresOnRecordAndStopsAfterRemoval() {
        let store = makeStore()
        var fireCount = 0
        let token = store.addChangeObserver { fireCount += 1 }
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1, output: 1))
        XCTAssertEqual(fireCount, 1)

        store.removeChangeObserver(token)
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1, output: 1))
        XCTAssertEqual(fireCount, 1)
    }

    // MARK: - Pricing

    func testPricing() throws {
        // Published rates with cache reads discounted; a guessed price is worse than an honest
        // blank, so a local or unrecognized model comes back nil rather than zero; and when such a
        // model is in the mix the store's figure is a floor, not a total — the caller has to be
        // able to say so.
        var priced = UsageTotals()
        priced.inputTokens = 1_000_000
        priced.outputTokens = 1_000_000
        priced.cachedInputTokens = 1_000_000
        // Sonnet 5: $2 input + $10 output + $0.20 cached.
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCost(modelId: "claude-sonnet-5", totals: priced)), 12.2, accuracy: 0.0001)

        var unpriced = UsageTotals()
        unpriced.inputTokens = 5_000_000
        unpriced.outputTokens = 5_000_000
        XCTAssertNil(ModelPricing.estimatedCost(modelId: "some-local-model", totals: unpriced))
        XCTAssertFalse(ModelPricing.isPriced(modelId: "some-local-model"))

        let store = makeStore()
        store.record(projectPath: "/a", trackKey: "main", providerId: "anthropic", modelId: "claude-sonnet-5", usage: usage(input: 1_000_000, output: 0))
        store.record(projectPath: "/a", trackKey: "main", providerId: "local", modelId: "llama-whatever", usage: usage(input: 9_000_000, output: 9_000_000))
        let estimate = store.estimatedCost()
        XCTAssertEqual(estimate.total, 2.0, accuracy: 0.0001)
        XCTAssertTrue(estimate.hasUnpricedModels)
    }

    func testFormatting() {
        // Tokens scale through K and M; a sub-cent cost reads as below a penny, not zero.
        let tokens: [(Int, String)] = [(999, "999"), (1_500, "1.5K"), (2_500_000, "2.50M")]
        for (count, expected) in tokens {
            XCTAssertEqual(UsageFormatting.tokens(count), expected, "\(count)")
        }
        let costs: [(Double, String)] = [(0.004, "<$0.01"), (0, "$0.00"), (12.5, "$12.50")]
        for (amount, expected) in costs {
            XCTAssertEqual(UsageFormatting.cost(amount), expected, "\(amount)")
        }
    }
}
