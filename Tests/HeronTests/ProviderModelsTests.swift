import XCTest
@testable import Heron

/// Keeping a provider's model list current: the built-in seeds merge into an older saved list,
/// and a provider's `/v1/models` answer merges in without losing models only the person knows.
final class ProviderModelsTests: XCTestCase {
    private func model(_ id: String, _ name: String? = nil, window: Int = 200_000) -> ProviderModel {
        ProviderModel(id: id, displayName: name ?? id, contextWindowTokens: window)
    }

    func testMergeListsTheProvidersModelsFirstAndKeepsTheRest() {
        let existing = [model("claude-opus-5", "Claude Opus 5"), model("my-finetune", window: 32_000), model("claude-sonnet-5", window: 1_000_000)]
        let fresh = [model("claude-opus-5-5", "Claude Opus 5.5"), model("claude-sonnet-5", "Claude Sonnet 5"), model("claude-opus-5", "Claude Opus 5")]
        let merged = ProviderRegistryStore.merge(existing, adding: fresh)
        XCTAssertEqual(merged.map(\.id), ["claude-opus-5-5", "claude-sonnet-5", "claude-opus-5", "my-finetune"])
        XCTAssertEqual(merged[1].contextWindowTokens, 1_000_000, "a window the person set stays")
        XCTAssertEqual(ProviderRegistryStore.merge(merged, adding: fresh), merged, "merging again changes nothing")
    }

    func testAnOlderSavedListGainsTheCurrentSeeds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ProviderRegistryStore(storeURL: url)
        var old = try XCTUnwrap(first.provider(for: "anthropic"))
        old.models = [model("claude-opus-5", "Claude Opus 5")]
        first.addOrUpdate(old)
        let reloaded = ProviderRegistryStore(storeURL: url)
        let ids = try XCTUnwrap(reloaded.provider(for: "anthropic")).models.map(\.id)
        XCTAssertTrue(ids.contains("claude-opus-5-5"))
        XCTAssertTrue(ids.contains("claude-opus-5"))
    }

    func testParsesAnthropicAndOpenAIShapes() throws {
        let anthropic = Data(#"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-08-01T00:00:00Z"}],"has_more":false}"#.utf8)
        XCTAssertEqual(ProviderRegistryStore.parseModels(anthropic), [model("claude-opus-5-5", "Claude Opus 5.5")])
        let openAI = Data(#"{"object":"list","data":[{"id":"llama3.2","object":"model"}]}"#.utf8)
        XCTAssertEqual(ProviderRegistryStore.parseModels(openAI)?.map(\.id), ["llama3.2"])
        XCTAssertNil(ProviderRegistryStore.parseModels(Data("nope".utf8)))
    }
}
