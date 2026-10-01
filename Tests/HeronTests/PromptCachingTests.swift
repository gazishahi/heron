import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, D1: the request shape a prompt cache can serve.
final class PromptCachingTests: XCTestCase {
    private let tools = [
        ToolSpec(name: "read_file", description: "Read a file.", inputSchema: .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])])),
        ToolSpec(name: "list_files", description: "List files.", inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
    ]
    private let history = [
        AgentMessage(role: .user, content: [.text("Read it.")]),
        AgentMessage(role: .assistant, content: [.toolUse(id: "t1", name: "read_file", input: .object(["path": .string("a.swift")]))]),
        AgentMessage(role: .user, content: [.toolResult(toolUseId: "t1", content: "let a = 1", isError: false)]),
    ]

    private func anthropic() -> AnthropicMessagesProvider {
        AnthropicMessagesProvider(apiKey: "k", modelId: "claude-sonnet-5")
    }

    func testAnthropicMarksTheSystemPromptAndTheLastBlock() throws {
        let body = anthropic().requestBody(messages: history, system: "Be brief.", tools: tools)
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["text"] as? String, "Be brief.")
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        // The system prompt's breakpoint covers the tools, which render before it.
        XCTAssertFalse((body["tools"] as? [[String: Any]] ?? []).contains { $0["cache_control"] != nil })
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let marked = messages.enumerated().flatMap { index, message in
            (message["content"] as? [[String: Any]] ?? []).enumerated().filter { $0.element["cache_control"] != nil }.map { (index, $0.offset) }
        }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.0, 2, "the last message")
        XCTAssertEqual(messages[2]["content"].map { ($0 as? [Any])?.count }, 1)
    }

    /// Compaction's request has no system prompt: the tools carry the first breakpoint instead.
    func testWithoutASystemPromptTheToolsAreMarked() throws {
        let body = anthropic().requestBody(messages: history, system: nil, tools: tools)
        XCTAssertNil(body["system"])
        let toolJSON = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertNil(toolJSON[0]["cache_control"])
        XCTAssertNotNil(toolJSON[1]["cache_control"])
    }

    /// The same request is the same bytes: JSONSerialization's key order isn't stable without it.
    func testTheSameRequestIsTheSameBytes() throws {
        let provider = anthropic()
        let first = try JSONSerialization.data(withJSONObject: provider.requestBody(messages: history, system: "s", tools: tools), options: .sortedKeys)
        for _ in 0..<20 {
            let again = try JSONSerialization.data(withJSONObject: provider.requestBody(messages: history, system: "s", tools: tools), options: .sortedKeys)
            XCTAssertEqual(again, first)
        }
    }

    func testOnlyOpenAIGetsAPromptCacheKey() {
        let openAI = OpenAICompatibleChatProvider(apiKey: "k", modelId: "gpt-5", baseURL: URL(string: "https://api.openai.com/v1")!)
        let local = OpenAICompatibleChatProvider(apiKey: nil, modelId: "qwen", baseURL: URL(string: "http://localhost:11434/v1")!, asksForStreamUsage: false)
        let key = openAI.requestBody(messages: history, system: "s", tools: tools)["prompt_cache_key"] as? String
        XCTAssertNotNil(key)
        XCTAssertEqual(openAI.requestBody(messages: history + history, system: "s", tools: tools)["prompt_cache_key"] as? String, key, "the conversation's growth doesn't change it")
        XCTAssertNotEqual(openAI.requestBody(messages: history, system: "other", tools: tools)["prompt_cache_key"] as? String, key)
        XCTAssertNil(local.requestBody(messages: history, system: "s", tools: tools)["prompt_cache_key"])
    }

    /// A turn's notes go to the model after what was typed, and a turn saved before notes loads.
    func testNotesAreSentAndStoredButArentContent() throws {
        let turn = AgentTurn(role: .user, content: [.text("Look at @a.swift")], notes: ["[paths: a.swift]"])
        XCTAssertEqual(turn.content.count, 1)
        XCTAssertEqual(turn.message.content.count, 2)
        if case .text(let note) = turn.message.content[1] { XCTAssertEqual(note, "[paths: a.swift]") } else { XCTFail() }
        let decoded = try JSONDecoder().decode(AgentTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(decoded.notes, ["[paths: a.swift]"])
        XCTAssertNil(AgentTurn(role: .user, content: [.text("hi")], notes: []).notes)

        let oldJSON = try JSONEncoder().encode(AgentTurn(role: .user, content: [.text("hi")]))
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("notes"), "no field when there are none")
        let reloaded = try JSONDecoder().decode(AgentTurn.self, from: oldJSON)
        XCTAssertNil(reloaded.notes)
        XCTAssertEqual(reloaded.message.content.count, 1)
    }

    /// H6: Claude 5 thinks by default and shares the ceiling with the answer; 8,192 cut off
    /// large writes. Thinking is always summarized, so it shows.
    func testClaude5HasRoomAndShowsItsThinking() throws {
        let body = AnthropicMessagesProvider(apiKey: "k", modelId: "claude-sonnet-5").requestBody(messages: history, system: "s", tools: tools)
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertEqual(thinking["display"] as? String, "summarized")
        XCTAssertNil(body["output_config"], "standard is the model's own default effort")
        let high = AnthropicMessagesProvider(apiKey: "k", modelId: "claude-opus-5-5", effort: .high).requestBody(messages: history, system: "s", tools: tools)
        XCTAssertEqual((high["output_config"] as? [String: Any])?["effort"] as? String, "high")
        // Older models keep the budget form and their own ceiling.
        let older = AnthropicMessagesProvider(apiKey: "k", modelId: "claude-haiku-4-5-20251001").requestBody(messages: history, system: "s", tools: tools)
        XCTAssertEqual(older["max_tokens"] as? Int, 8192)
        XCTAssertNil(older["thinking"])
    }
}
