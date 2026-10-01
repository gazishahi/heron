import Foundation

/// Adapter for the OpenAI chat-completions wire shape (`POST {baseURL}/chat/completions`, SSE
/// streaming) — deliberately generic rather than "the OpenAI adapter," since Ollama and LM
/// Studio both mimic this exact shape. This one file is what makes OpenAI BYOK and local models
/// both work with zero extra adapter code: only `baseURL` (and whether a key is required)
/// differs between them, and that lives in `ProviderDefinition`, not here.
///
/// `baseURL` is expected to already include the API version root (e.g.
/// `https://api.openai.com/v1`, `http://localhost:11434/v1`) — this adapter only appends
/// `/chat/completions` to it.
public final class OpenAICompatibleChatProvider: ChatModelProvider {
    private let apiKey: String?
    private let modelId: String
    private let baseURL: URL
    private let contextWindowTokens: Int
    private let effort: AgentEffort

    /// Whether to ask for usage in the stream (`stream_options`): hosted services, yes; a local
    /// server, not (some refuse an unknown field, and a local model costs nothing).
    private let asksForStreamUsage: Bool

    public init(apiKey: String?, modelId: String, baseURL: URL, contextWindowTokens: Int = 128_000, effort: AgentEffort = .standard, asksForStreamUsage: Bool = true) {
        self.asksForStreamUsage = asksForStreamUsage
        self.apiKey = apiKey
        self.modelId = modelId
        self.baseURL = baseURL
        self.contextWindowTokens = contextWindowTokens
        self.effort = effort
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(supportsToolUse: true, supportsStreaming: true, contextWindowTokens: contextWindowTokens, supportsPromptCaching: false)
    }

    public func streamTurn(
        messages: [AgentMessage],
        system: String?,
        tools: [ToolSpec],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sorted keys: the same request is the same bytes every time, which is what a server's
        // prefix cache matches on (SIDE_RFC_HERON_EFFICIENCY.md, D1).
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system, tools: tools), options: .sortedKeys)

        let state = TurnState()
        do {
            try await SSEHTTPClient.stream(request: request) { sse in
                if Self.handle(sse: sse, state: state, onEvent: onEvent) { state.ended = true }
            }
            // A server that gave its finish reason and closed without `[DONE]` still finished;
            // the runner treats a reply with no end as cut off and won't run its tool calls.
            if !state.ended, state.finishReason != nil {
                Self.handle(sse: SSEEvent(event: nil, data: "[DONE]"), state: state, onEvent: onEvent)
            }
        } catch let error as SSEHTTPClientError {
            guard case .httpError(let statusCode, let body) = error else { throw error }
            onEvent(.error(Self.providerError(fromHTTPStatus: statusCode, body: body)))
        }
    }

    // MARK: - Request building

    func requestBody(messages: [AgentMessage], system: String?, tools: [ToolSpec]) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "stream": true,
            // Without this OpenAI streams no usage at all, and nothing is metered. Servers that
            // don't know it (older local ones) ignore it; the ones that know it answer.
            "messages": Self.openAIMessages(from: messages, system: system),
        ]
        if asksForStreamUsage { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.inputSchema.anyValue]]
            }
            body["tool_choice"] = "auto"
        }
        // Only sent when the user actually asked for it — some OpenAI-compatible servers 400 on
        // an unknown field, and every local model is one of those.
        // OpenAI caches a long enough prefix by itself; the key routes requests that share one
        // to the same cache. OpenAI's own field, so only OpenAI gets it — the tools and system
        // prompt name the prefix, which is what the requests of one mode share.
        if baseURL.host == "api.openai.com" {
            body["prompt_cache_key"] = Self.promptCacheKey(modelId: modelId, system: system, tools: tools)
        }
        if let reasoning = effort.openAIReasoningEffort {
            body["reasoning_effort"] = reasoning
        }
        return body
    }

    /// A short stable name for the prefix: FNV-1a over the model, the system prompt and the tool
    /// names. Not a secret and not unique — a routing hint.
    static func promptCacheKey(modelId: String, system: String?, tools: [ToolSpec]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in ([modelId, system ?? ""] + tools.map(\.name)).joined(separator: "\u{1F}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "heron-" + String(hash, radix: 16)
    }

    /// Unlike Anthropic (one content-block array per turn), OpenAI wants one message per role
    /// occurrence: a single assistant message carries its own text *and* every tool call it
    /// made in one shot, and each tool result is its own separate `role: "tool"` message rather
    /// than several content blocks bundled into one user message.
    private static func openAIMessages(from messages: [AgentMessage], system: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let system, !system.isEmpty {
            result.append(["role": "system", "content": system])
        }
        for message in messages {
            switch message.role {
            case .system:
                continue // already folded into the top-level system message above
            case .user, .tool:
                var textParts: [String] = []
                var imageParts: [[String: Any]] = []
                var toolResultMessages: [[String: Any]] = []
                for block in message.content {
                    switch block {
                    case .text(let text): textParts.append(text)
                    case .toolResult(let toolUseId, let content, _):
                        toolResultMessages.append(["role": "tool", "tool_call_id": toolUseId, "content": content])
                    case .image(let mediaType, let base64):
                        // OpenAI's inline-image shape: a data URL inside an image_url part.
                        imageParts.append(["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]])
                    case .toolUse: break // never appears in a user-role turn
                    }
                }
                if !imageParts.isEmpty {
                    // With images the content must be the array-of-parts form; text joins in.
                    var parts = imageParts
                    if !textParts.isEmpty { parts.append(["type": "text", "text": textParts.joined(separator: "\n")]) }
                    result.append(["role": "user", "content": parts])
                } else if !textParts.isEmpty {
                    result.append(["role": "user", "content": textParts.joined(separator: "\n")])
                }
                result.append(contentsOf: toolResultMessages)
            case .assistant:
                var textParts: [String] = []
                var toolCalls: [[String: Any]] = []
                for block in message.content {
                    switch block {
                    case .text(let text): textParts.append(text)
                    case .toolUse(let id, let name, let input):
                        let argumentsData = (try? JSONSerialization.data(withJSONObject: input.anyValue, options: .sortedKeys)) ?? Data("{}".utf8)
                        let argumentsString = String(data: argumentsData, encoding: .utf8) ?? "{}"
                        toolCalls.append(["id": id, "type": "function", "function": ["name": name, "arguments": argumentsString]])
                    case .toolResult, .image: break // never appear in an assistant-role turn
                    }
                }
                var assistantMessage: [String: Any] = ["role": "assistant", "content": textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n")]
                if !toolCalls.isEmpty { assistantMessage["tool_calls"] = toolCalls }
                result.append(assistantMessage)
            }
        }
        return result
    }

    // MARK: - Stream parsing

    /// Per-turn accumulation across SSE chunks. Only touched from the SSE callback, which
    /// `SSEHTTPClient` invokes serially from the awaiting task — no synchronization needed.
    // Internal so the parser can be driven from tests — see the note on AnthropicMessagesProvider.
    public final class TurnState {
        /// OpenAI streams tool calls as deltas keyed by array *index*, with the id/name arriving
        /// only on the first chunk for that index and `arguments` streaming incrementally after
        /// — the same index-keyed-delta shape Anthropic uses for content blocks, just for tool
        /// calls specifically rather than every block.
        public var toolCallsByIndex: [Int: String] = [:] // index -> id
        public var finishReason: String?
        public var ended = false
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var cachedTokens: Int?

        public init() {}
    }

    /// Returns `true` once the terminal `[DONE]` marker arrives, so the caller knows the stream
    /// is finished — unlike Anthropic's explicit `message_stop` event type, OpenAI signals end
    /// of stream with a literal, non-JSON sentinel payload.
    @discardableResult
    public static func handle(sse: SSEEvent, state: TurnState, onEvent: (AgentStreamEvent) -> Void) -> Bool {
        if sse.data == "[DONE]" {
            for id in state.toolCallsByIndex.values { onEvent(.toolUseEnd(id: id)) }
            // OpenAI's prompt count includes what it served from its cache; Side's input is
            // what was billed at the full price.
            let usage = state.promptTokens.map { prompt in
                TokenUsage(inputTokens: max(0, prompt - (state.cachedTokens ?? 0)), outputTokens: state.completionTokens ?? 0,
                           cachedInputTokens: state.cachedTokens)
            }
            onEvent(.messageEnd(stopReason: stopReason(from: state.finishReason), usage: usage))
            return true
        }
        guard let data = sse.data.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let usage = object["usage"] as? [String: Any] {
            state.promptTokens = usage["prompt_tokens"] as? Int
            state.completionTokens = usage["completion_tokens"] as? Int
            state.cachedTokens = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return false }
        if let finishReason = choice["finish_reason"] as? String { state.finishReason = finishReason }
        guard let delta = choice["delta"] as? [String: Any] else { return false }
        if let content = delta["content"] as? String, !content.isEmpty {
            onEvent(.textDelta(content))
        }
        // No standard field here — this adapter covers OpenAI, Ollama, LM Studio, and anything
        // else speaking the same shape, and they disagree. Both spellings in the wild are
        // accepted; a server that sends neither simply shows no reasoning, exactly as before.
        for key in ["reasoning_content", "reasoning"] {
            if let reasoning = delta[key] as? String, !reasoning.isEmpty {
                onEvent(.thinkingDelta(reasoning))
                break
            }
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let index = call["index"] as? Int else { continue }
                let function = call["function"] as? [String: Any]
                if state.toolCallsByIndex[index] == nil, let id = call["id"] as? String, let name = function?["name"] as? String {
                    state.toolCallsByIndex[index] = id
                    onEvent(.toolUseStart(id: id, name: name))
                }
                if let id = state.toolCallsByIndex[index], let arguments = function?["arguments"] as? String, !arguments.isEmpty {
                    onEvent(.toolUseInputDelta(id: id, partialJSON: arguments))
                }
            }
        }
        return false
    }

    private static func stopReason(from raw: String?) -> StopReason {
        switch raw {
        case "stop": return .endTurn
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case let other?: return .other(other)
        case nil: return .endTurn
        }
    }

    private static func providerError(fromHTTPStatus statusCode: Int, body: String) -> AgentProviderError {
        if let data = body.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return AgentProviderError(message: message, typeSlug: error["type"] as? String)
        }
        return AgentProviderError(message: "HTTP \(statusCode): \(body.prefix(500))", typeSlug: nil)
    }
}
