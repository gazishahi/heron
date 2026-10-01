import Foundation

// Heron's normalized core: every provider adapter translates its own wire shape into these
// types and nothing above the adapter layer ever sees a provider-specific field. Anthropic
// quirks live in AnthropicMessagesProvider; OpenAI-compatible quirks will live in that
// adapter when it lands (Phase 6) — never here.

/// One JSON value of arbitrary shape. Needed because tool-call arguments are arbitrary JSON
/// decided by the model at runtime — unlike LSP params, which are always statically typed
/// Swift structs, so nothing in the LSP layer ever needed this.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    /// Bridge to JSONSerialization's world — adapters build request bodies as [String: Any]
    /// dictionaries, and tool inputs embedded in them need to cross over.
    public var anyValue: Any {
        switch self {
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .array(let array): return array.map(\.anyValue)
        case .object(let object): return object.mapValues(\.anyValue)
        }
    }
}

public struct AgentMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: [AgentContentBlock]

    public init(role: Role, content: [AgentContentBlock]) {
        self.role = role
        self.content = content
    }
}

public enum AgentContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// A user-attached image, inline as base64. Inline rather than a file reference on purpose:
    /// the image is *part of the conversation* — it must survive with the turn, ride every
    /// replay, and vanish with compaction, all of which fall out of storing it in the turn
    /// itself. The composer downscales before attaching (longest side ≤ 1568px, the API's
    /// sweet spot), which keeps a screenshot to a few hundred KB.
    case image(mediaType: String, base64: String)
}

/// What the composer hands the runner per attached image — already downscaled and encoded.
public struct AgentImageAttachment: Sendable {
    public let mediaType: String
    public let base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

public struct ToolSpec: Codable, Sendable {
    public let name: String
    public let description: String
    /// JSON Schema, kept as raw JSON — both target wire formats (Anthropic `input_schema`,
    /// OpenAI `parameters`) accept the same schema object verbatim.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum StopReason: Equatable, Sendable {
    case endTurn, toolUse, maxTokens, stopSequence
    case other(String)
}

public struct TokenUsage: Sendable, Equatable {
    /// Input billed at the full price: not read from the cache, not written to it.
    public let inputTokens: Int
    public let outputTokens: Int
    /// Input read from the provider's prompt cache (a fraction of the price).
    public let cachedInputTokens: Int?
    /// Input written to the cache this request (Anthropic: 1.25x the price, for 5 minutes).
    public let cacheWriteInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int?, cacheWriteInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
    }

    /// Everything the request carried, however it was billed: what the context gauge counts.
    public var promptTokens: Int { inputTokens + (cachedInputTokens ?? 0) + (cacheWriteInputTokens ?? 0) }
}

/// Provider-level failure (bad key, rate limit, overloaded) — distinct from transport-level
/// failure, which `streamTurn` throws instead. A caller mid-stream needs to know *when* in
/// the stream a provider error happened, which is why these arrive as events.
public struct AgentProviderError: Error, Sendable {
    public let message: String
    /// Provider-specific error slug when one was given, e.g. "authentication_error".
    public let typeSlug: String?

    public init(message: String, typeSlug: String?) {
        self.message = message
        self.typeSlug = typeSlug
    }
}

public enum AgentStreamEvent: Sendable {
    case textDelta(String)
    /// A fragment of the model's reasoning.
    ///
    /// **Display only.** These are deliberately not added to the persisted turn or sent back on
    /// the next request, which keeps the wire format byte-identical to what already works. The
    /// cost is that the model doesn't see its own earlier reasoning across round trips — already
    /// true today, since this was dropped entirely. Passing thinking back is a separate change
    /// with its own hazard (Anthropic requires the block's `signature` to survive intact), and
    /// worth doing on purpose rather than as a side effect of making it visible.
    case thinkingDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseInputDelta(id: String, partialJSON: String)
    case toolUseEnd(id: String)
    case messageEnd(stopReason: StopReason, usage: TokenUsage?)
    case error(AgentProviderError)
}

/// Static capability description the UI and tool layer can inspect without a network call —
/// e.g. to know whether to even offer tool-use for a model. Local servers will override these
/// via their registry entry (Phase 6).
public struct ProviderCapabilities: Sendable {
    public let supportsToolUse: Bool
    public let supportsStreaming: Bool
    public let contextWindowTokens: Int
    public let supportsPromptCaching: Bool

    public init(supportsToolUse: Bool, supportsStreaming: Bool, contextWindowTokens: Int, supportsPromptCaching: Bool) {
        self.supportsToolUse = supportsToolUse
        self.supportsStreaming = supportsStreaming
        self.contextWindowTokens = contextWindowTokens
        self.supportsPromptCaching = supportsPromptCaching
    }
}

public protocol ChatModelProvider {
    var capabilities: ProviderCapabilities { get }

    /// One streaming turn. `onEvent` fires on an arbitrary background context; callers hop to
    /// main themselves, same convention LSPManager already uses. Throws only for
    /// transport-level failure — provider-level errors arrive as `.error` events instead.
    /// Streaming-only by design: a non-streaming call is just "stream and buffer," which a
    /// caller can do trivially, so the protocol doesn't carry the extra surface.
    func streamTurn(
        messages: [AgentMessage],
        system: String?,
        tools: [ToolSpec],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws
}
