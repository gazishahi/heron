import Foundation

/// Adapter for Anthropic's Messages API (`POST /v1/messages`, SSE streaming). Every
/// Anthropic-only concern — the `x-api-key`/`anthropic-version` headers, the Messages event
/// vocabulary (`content_block_start`/`content_block_delta`/…) — lives inside this file and
/// is translated into Heron's normalized AgentStreamEvent before anything else sees it.
public final class AnthropicMessagesProvider: ChatModelProvider {
    private let apiKey: String
    private let modelId: String
    private let baseURL: URL
    private let maxTokens: Int
    private let effort: AgentEffort

    public init(
        apiKey: String, modelId: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
        maxTokens: Int = 8192, effort: AgentEffort = .standard
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.baseURL = baseURL
        // Extended thinking spends tokens before the answer starts, so the budget form's
        // ceiling has to make room for both — see `AgentEffort.anthropicMaxTokens`. Adaptive
        // thinking manages its own, so the ceiling stays where it was.
        //
        // Claude 5 thinks by default, even with no `thinking` field, and its thinking shares the
        // ceiling with the answer, so 8,192 cut off any large file write mid-call (2026-09-30
        // audit, H6). Streaming allows far more; output is billed as it's used, not by the cap.
        self.maxTokens = Self.usesAdaptiveThinking(modelId: modelId)
            ? max(maxTokens, Self.adaptiveMaxTokens)
            : effort.anthropicMaxTokens(base: maxTokens)
        self.effort = effort
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(supportsToolUse: true, supportsStreaming: true, contextWindowTokens: 200_000, supportsPromptCaching: true)
    }

    public func streamTurn(
        messages: [AgentMessage],
        system: String?,
        tools: [ToolSpec],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sorted keys: a cache hit needs the prefix byte for byte, and a dictionary's order isn't
        // stable (SIDE_RFC_HERON_EFFICIENCY.md, D1 — unsorted, consecutive requests shared nothing).
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system, tools: tools), options: .sortedKeys)

        let state = TurnState()
        // However the stream ends (Stop's cancellation included), a started reply is counted.
        defer { if let usage = state.unfinishedUsage { onEvent(.usageWithoutEnd(usage)) } }
        do {
            try await SSEHTTPClient.stream(request: request) { sse in
                Self.handle(sse: sse, state: state, onEvent: onEvent)
            }
        } catch let error as SSEHTTPClientError {
            // Non-200 responses are provider-level failures (bad key, rate limit, overloaded)
            // — per the ChatModelProvider contract they surface as an .error event, not a
            // throw. The body is Anthropic's own error JSON when it can be parsed.
            guard case .httpError(let statusCode, let body) = error else { throw error }
            onEvent(.error(Self.providerError(fromHTTPStatus: statusCode, body: body)))
        }
    }

    /// Model-family check rather than a capability flag on `ProviderModel`: the split is
    /// Anthropic's own API-version detail, so it belongs in Anthropic's adapter. A BYOK provider
    /// naming a Claude 5 model gets the same treatment, which is what you want.
    /// The output ceiling for Claude 5: room for thinking and a large write together.
    static let adaptiveMaxTokens = 64_000

    public static func usesAdaptiveThinking(modelId: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"].contains { modelId.hasPrefix($0) }
    }

    // MARK: - Request building

    /// The 5-minute cache (the owner's choice, SIDE_RFC_HERON_EFFICIENCY.md, Q4): a round trip
    /// reads it well inside five minutes, and every read renews it.
    static var cacheControl: [String: Any] { ["type": "ephemeral"] }

    func requestBody(messages: [AgentMessage], system: String?, tools: [ToolSpec]) -> [String: Any] {
        // System messages never appear in the messages array — Anthropic takes the system prompt
        // as a top-level field, so .system roles are filtered out.
        var messageJSON = messages.filter { $0.role != .system }.map { message -> [String: Any] in
            [
                // Anthropic has no "tool" role — tool results travel as content blocks inside a
                // user message.
                "role": message.role == .assistant ? "assistant" : "user",
                "content": message.content.map(Self.contentBlockJSON),
            ]
        }
        // Two cache breakpoints (D1). The API renders tools, then system, then messages, and a
        // breakpoint caches everything before it:
        //  - on the system prompt, which with the tools is the same for every request in a mode,
        //    so a new conversation starts from a hit;
        //  - on the last block of the last message, so each round trip reads the whole history
        //    the previous one wrote and writes only what it added. The previous round trip's
        //    breakpoint sits a few blocks back, well inside the API's 20-block lookback.
        // A prefix under the model's minimum (512–4,096 tokens) just isn't cached; no error.
        if var last = messageJSON.last, var content = last["content"] as? [[String: Any]], !content.isEmpty {
            content[content.count - 1]["cache_control"] = Self.cacheControl
            last["content"] = content
            messageJSON[messageJSON.count - 1] = last
        }
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messageJSON,
        ]
        if let system, !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": Self.cacheControl]]
        }
        if !tools.isEmpty {
            var toolJSON: [[String: Any]] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema.anyValue] }
            // No system prompt (compaction's request): the tools' own breakpoint.
            if system?.isEmpty ?? true { toolJSON[toolJSON.count - 1]["cache_control"] = Self.cacheControl }
            body["tools"] = toolJSON
        }
        // Omitted entirely at `.standard`: the API rejects a budget below its minimum, so
        // "no thinking" has to mean "no block," not "a zero budget."
        //
        // Which shape depends on the model, and this was found the only way it could be — by a
        // real request coming back rejected: Claude 5 refuses `thinking.type.enabled` and asks
        // for `thinking.type.adaptive` + `output_config.effort`, while 4.x only knows the
        // budget form.
        if Self.usesAdaptiveThinking(modelId: modelId) {
            // Summarized, always: Claude 5 thinks whether or not it's asked to, and its default
            // display is "omitted", which streamed the thinking group empty. Display changes
            // only what's shown; the thinking is the same, and billed the same.
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            // Standard is the model's own default effort; the others are explicit.
            if let effortName = effort.anthropicOutputEffort {
                body["output_config"] = ["effort": effortName]
            }
        } else if let budget = effort.anthropicThinkingBudget {
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }
        return body
    }

    private static func contentBlockJSON(_ block: AgentContentBlock) -> [String: Any] {
        switch block {
        case .text(let text):
            return ["type": "text", "text": text]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": id, "name": name, "input": input.anyValue]
        case .toolResult(let toolUseId, let content, let isError):
            return ["type": "tool_result", "tool_use_id": toolUseId, "content": content, "is_error": isError]
        case .image(let mediaType, let base64):
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
        }
    }

    // MARK: - Stream parsing

    /// Per-turn accumulation across SSE frames. Only ever touched from the SSE callback,
    /// which SSEHTTPClient invokes serially from the awaiting task — no synchronization
    /// needed.
    // Internal, not private, so the SSE parser can be driven directly from tests. It is the
    // component most able to break silently — a renamed field in a provider's event shape shows
    // up as an agent that simply says nothing.
    public final class TurnState {
        public var toolUseIdsByIndex: [Int: String] = [:]
        public var stopReason: StopReason = .endTurn
        public var inputTokens: Int?
        public var cachedInputTokens: Int?
        public var cacheWriteInputTokens: Int?
        public var outputTokens: Int?
        /// `message_stop` arrived.
        public var ended = false
        /// Characters of text, thinking and tool input streamed so far: the output estimate when
        /// the reply ends early, at about four to a token.
        public var streamedCharacters = 0

        public init() {}

        /// What a reply that ended before `message_stop` was billed, as far as is known: nil
        /// once it ended, or if it never started.
        public var unfinishedUsage: TokenUsage? {
            guard !ended, let input = inputTokens else { return nil }
            return TokenUsage(inputTokens: input, outputTokens: outputTokens ?? (streamedCharacters + 3) / 4,
                              cachedInputTokens: cachedInputTokens, cacheWriteInputTokens: cacheWriteInputTokens)
        }
    }

    public static func handle(sse: SSEEvent, state: TurnState, onEvent: (AgentStreamEvent) -> Void) {
        guard let data = sse.data.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch sse.event ?? (object["type"] as? String) ?? "" {
        case "message_start":
            if let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                state.inputTokens = usage["input_tokens"] as? Int
                state.cachedInputTokens = usage["cache_read_input_tokens"] as? Int
                state.cacheWriteInputTokens = usage["cache_creation_input_tokens"] as? Int
            }
        case "content_block_start":
            // Text blocks need no start marker — their deltas carry everything. Tool-use
            // blocks do: the id/name arrive here and only the input streams as deltas, and
            // deltas are keyed by block *index* on the wire, so remember index → id.
            if let index = object["index"] as? Int,
               let block = object["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                state.toolUseIdsByIndex[index] = id
                onEvent(.toolUseStart(id: id, name: name))
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { state.streamedCharacters += text.utf16.count; onEvent(.textDelta(text)) }
            case "thinking_delta":
                // Claude 4 and later return *summarized* thinking, so this is already the short
                // form rather than the full chain — which is exactly what belongs in a collapsed
                // activity group. `signature_delta` is deliberately ignored: it exists to let a
                // thinking block be passed back intact, and nothing here passes them back.
                if let thinking = delta["thinking"] as? String { state.streamedCharacters += thinking.utf16.count; onEvent(.thinkingDelta(thinking)) }
            case "input_json_delta":
                if let index = object["index"] as? Int, let id = state.toolUseIdsByIndex[index],
                   let partial = delta["partial_json"] as? String {
                    state.streamedCharacters += partial.utf16.count
                    onEvent(.toolUseInputDelta(id: id, partialJSON: partial))
                }
            default:
                break
            }
        case "content_block_stop":
            if let index = object["index"] as? Int, let id = state.toolUseIdsByIndex[index] {
                onEvent(.toolUseEnd(id: id))
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any], let raw = delta["stop_reason"] as? String {
                state.stopReason = stopReason(from: raw)
            }
            if let usage = object["usage"] as? [String: Any] {
                state.outputTokens = usage["output_tokens"] as? Int
                // The final counts, when the API repeats them here.
                if let input = usage["input_tokens"] as? Int { state.inputTokens = input }
                if let read = usage["cache_read_input_tokens"] as? Int { state.cachedInputTokens = read }
                if let write = usage["cache_creation_input_tokens"] as? Int { state.cacheWriteInputTokens = write }
            }
        case "message_stop":
            state.ended = true
            let usage = TokenUsage(inputTokens: state.inputTokens ?? 0, outputTokens: state.outputTokens ?? 0,
                                   cachedInputTokens: state.cachedInputTokens, cacheWriteInputTokens: state.cacheWriteInputTokens)
            onEvent(.messageEnd(stopReason: state.stopReason, usage: usage))
        case "error":
            let error = object["error"] as? [String: Any]
            onEvent(.error(AgentProviderError(message: error?["message"] as? String ?? "Unknown provider error", typeSlug: error?["type"] as? String)))
        default:
            break // ping and future event types
        }
    }

    private static func stopReason(from raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        default: return .other(raw)
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
