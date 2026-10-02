import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, D5: every token counted as it's billed, every model priced.
final class UsageAccountingTests: XCTestCase {
    private func anthropic(_ events: [(String, String)]) -> TokenUsage? {
        let state = AnthropicMessagesProvider.TurnState()
        var usage: TokenUsage?
        for (name, data) in events {
            AnthropicMessagesProvider.handle(sse: SSEEvent(event: name, data: data), state: state) { event in
                if case .messageEnd(_, let reported) = event { usage = reported }
            }
        }
        return usage
    }

    func testAnthropicCountsCacheReadsAndWrites() throws {
        let usage = try XCTUnwrap(anthropic([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":40000,"cache_creation_input_tokens":3500,"output_tokens":1}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":210}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]))
        XCTAssertEqual(usage, TokenUsage(inputTokens: 120, outputTokens: 210, cachedInputTokens: 40_000, cacheWriteInputTokens: 3_500))
        XCTAssertEqual(usage.promptTokens, 43_620, "the gauge counts everything the request carried")
    }

    func testOpenAIAsksForUsageAndSplitsOutWhatWasCached() throws {
        let hosted = OpenAICompatibleChatProvider(apiKey: "k", modelId: "gpt", baseURL: URL(string: "https://api.openai.com/v1")!)
        let body = hosted.requestBody(messages: [], system: nil, tools: [])
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let local = OpenAICompatibleChatProvider(apiKey: nil, modelId: "llama", baseURL: URL(string: "http://localhost:11434/v1")!, asksForStreamUsage: false)
        XCTAssertNil(local.requestBody(messages: [], system: nil, tools: [])["stream_options"], "a local server isn't sent a field it may refuse")

        let state = OpenAICompatibleChatProvider.TurnState()
        var usage: TokenUsage?
        for data in [
            #"{"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":5000,"completion_tokens":80,"prompt_tokens_details":{"cached_tokens":4096}}}"#,
            "[DONE]",
        ] {
            OpenAICompatibleChatProvider.handle(sse: SSEEvent(event: nil, data: data), state: state) { event in
                if case .messageEnd(_, let reported) = event { usage = reported }
            }
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 904, outputTokens: 80, cachedInputTokens: 4_096))
    }

    func testEveryModelSideOffersHasAPrice() {
        for provider in ProviderRegistryStore.builtInSeeds {
            for model in provider.models {
                XCTAssertTrue(ModelPricing.isPriced(modelId: model.id), "\(model.id) has no price: the monthly budget can't see it")
            }
        }
    }

    func testCostsFollowThePublishedRates() throws {
        // Opus 5.5: $4 in, $20 out, a cache hit 0.05x ($0.20), a 5-minute write 1.25x ($5).
        let totals = UsageTotals(inputTokens: 1_000_000, outputTokens: 1_000_000, cachedInputTokens: 1_000_000, cacheWriteInputTokens: 1_000_000, requestCount: 1)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCost(modelId: "claude-opus-5-5", totals: totals)), 4 + 20 + 0.20 + 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCost(modelId: "claude-fable-5-1", totals: totals)), 10 + 50 + 0.25 + 12.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCost(modelId: "claude-sonnet-5", totals: totals)), 2 + 10 + 0.2 + 2.5, accuracy: 0.0001)
        // The saving: a million cached tokens at Sonnet 5's $2 less $0.20, less the write's premium.
        let cached = UsageTotals(cachedInputTokens: 1_000_000, cacheWriteInputTokens: 100_000)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.cacheSaving(modelId: "claude-sonnet-5", totals: cached)), 1.8 - 0.05, accuracy: 0.0001)
    }

    func testUsageKeptBeforeCacheWritesStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A row written the store's way, then the new field taken out: a file from before it existed.
        UsageStore(storeURL: url).record(projectPath: "/p", trackKey: "", providerId: "anthropic", modelId: "claude-sonnet-5",
                                         usage: TokenUsage(inputTokens: 10, outputTokens: 5, cachedInputTokens: 2))
        JSONStore.flushPendingWrites()  // written a moment after it changes
        let text = try String(contentsOf: url, encoding: .utf8)
        let old = text.replacingOccurrences(of: #"\s*"cacheWriteInputTokens"\s*:\s*0,?"#, with: "", options: .regularExpression)
        XCTAssertFalse(old.contains("cacheWriteInputTokens"))
        try old.write(to: url, atomically: true, encoding: .utf8)
        let reloaded = UsageStore(storeURL: url)
        XCTAssertEqual(reloaded.records.first?.totals.inputTokens, 10)
        XCTAssertEqual(reloaded.records.first?.totals.cacheWriteInputTokens, 0)
    }
}

/// 2026-09-30 audit, H11: the budget couldn't see unpriced models, and the runner read the
/// app's shared usage store instead of its own.
@MainActor
final class BudgetBoundaryTests: XCTestCase {
    override func tearDown() { UsageBudget.monthlyLimitUSD = nil }

    func testDatedAndVariantIdsArePricedButFutureModelsArent() {
        XCTAssertNotNil(ModelPricing.price(modelId: "claude-haiku-4-5-20251001"))
        XCTAssertNotNil(ModelPricing.price(modelId: "claude-haiku-4-5"))
        XCTAssertEqual(ModelPricing.price(modelId: "claude-opus-5-5-20261001")?.inputPerMillion, 4, "the longer family wins")
        XCTAssertEqual(ModelPricing.price(modelId: "claude-opus-5[1m]")?.inputPerMillion, 5)
        XCTAssertNotNil(ModelPricing.price(modelId: "claude-opus-4-8"))
        XCTAssertNil(ModelPricing.price(modelId: "claude-opus-5-9"), "not priced as claude-opus-5")
        XCTAssertNil(ModelPricing.price(modelId: "gpt-5"))
    }

    func testUnderABudgetAnUnpricedRemoteModelIsRefused() {
        XCTAssertFalse(UsageBudget.refusesUnpriced(modelId: "mystery-1", isLocal: false), "no budget, no refusal")
        UsageBudget.monthlyLimitUSD = 10
        XCTAssertTrue(UsageBudget.refusesUnpriced(modelId: "mystery-1", isLocal: false))
        XCTAssertFalse(UsageBudget.refusesUnpriced(modelId: "qwen3:32b", isLocal: true), "local models cost nothing")
        XCTAssertFalse(UsageBudget.refusesUnpriced(modelId: "claude-sonnet-5", isLocal: false))
    }

    func testTheRunnerChecksItsOwnUsageStore() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { _, _ in .text("Hi.") }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }
        // $2 of this runner's own spend against a $1 limit.
        heron.usage.record(projectPath: project.path, trackKey: "", providerId: "anthropic", modelId: "claude-sonnet-5",
                           usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0, cachedInputTokens: nil))
        UsageBudget.monthlyLimitUSD = 1
        XCTAssertEqual(heron.send("Hello?", timeout: 10), .blocked(.budgetReached))
        XCTAssertEqual(server.requests.count, 0)
    }

    // MARK: HER-6 / PRV-3: replies that never finish are billed, and counted

    /// A reply that streamed and stopped: its input as `message_start` gave it, its output
    /// estimated from what streamed. Nothing for one that finished (its end counts) or never
    /// started.
    func testAnUnfinishedReplyKnowsWhatItCost() {
        let state = AnthropicMessagesProvider.TurnState()
        XCTAssertNil(state.unfinishedUsage, "never started")
        for (name, data) in [
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":900,"cache_read_input_tokens":30000,"output_tokens":1}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(String(repeating: "a", count: 400))"}}"#),
        ] {
            AnthropicMessagesProvider.handle(sse: SSEEvent(event: name, data: data), state: state) { _ in }
        }
        XCTAssertEqual(state.unfinishedUsage, TokenUsage(inputTokens: 900, outputTokens: 100, cachedInputTokens: 30_000, cacheWriteInputTokens: nil))
        AnthropicMessagesProvider.handle(sse: SSEEvent(event: "message_stop", data: #"{"type":"message_stop"}"#), state: state) { _ in }
        XCTAssertNil(state.unfinishedUsage, "finished: its messageEnd counts it")
    }

    /// An error part-way (overloaded): the request is in Usage, and so against the budget.
    func testAReplyCutOffByAnErrorIsCounted() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { _, _ in .cutToolCall(name: "read_file", partialInput: #"{"path":"RE"#, overloaded: true) }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }
        heron.send("Read the README.", timeout: 10)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(heron.totals.requestCount, 1)
        XCTAssertEqual(heron.totals.inputTokens, server.requests[0].count / 4, "the input message_start reported")
        XCTAssertGreaterThan(heron.totals.outputTokens, 0)
    }

    /// Stop in the middle of a reply: what it cost so far is counted.
    func testAStoppedReplyIsCounted() throws {
        let project = try HeronRequestMeasurementTests.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { _, _ in .streamedText(String(repeating: "word ", count: 2_000), delta: 5, duration: 5) }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }
        heron.runner.send("Write a long answer.")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !heron.runner.entries.contains(where: { if case .assistantText(let text) = $0.kind { return text.count > 200 } else { return false } }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        heron.runner.stop()
        let settled = Date().addingTimeInterval(5)
        while Date() < settled, heron.totals.requestCount == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(heron.totals.requestCount, 1)
        XCTAssertEqual(heron.totals.inputTokens, server.requests[0].count / 4)
        XCTAssertGreaterThan(heron.totals.outputTokens, 50, "estimated from what streamed")
        XCTAssertLessThan(heron.totals.outputTokens, 2_500, "not the whole reply")
    }
}
