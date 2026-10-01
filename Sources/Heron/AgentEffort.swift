import Foundation

/// How hard the model should think before answering — the second half of "which model," and the
/// reason picking a model in Side was previously a blunt instrument.
///
/// Every current frontier provider exposes this, and none of them agree on how: Anthropic takes a
/// `thinking` block with a token budget, OpenAI-shaped APIs take a `reasoning_effort` string.
/// This enum is Side's own vocabulary; each adapter translates it, and a provider that supports
/// neither simply ignores it (the request is then exactly what it was before this existed).
public enum AgentEffort: String, Codable, CaseIterable, Sendable {
    /// No extended thinking — fastest, cheapest, and the right default for a chat-shaped turn.
    case standard
    case low
    case medium
    case high

    public static let `default` = AgentEffort.standard

    public var displayName: String {
        switch self {
        // "Default": the model's own. Claude 5 models think at their own default effort, so
        // "Standard" read as "no thinking", and could cost more than Thinking · Low (the owner's
        // choice, 2026-09-30). The stored value stays `standard`.
        case .standard: return "Default"
        case .low: return "Thinking · Low"
        case .medium: return "Thinking · Medium"
        case .high: return "Thinking · High"
        }
    }

    /// Compact form for a header that already carries provider, model, tokens, and cost.
    public var shortLabel: String {
        switch self {
        case .standard: return "standard"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    /// The Claude 5 family's own vocabulary: `thinking: {type: adaptive}` plus
    /// `output_config: {effort: …}`. `nil` at `.standard`, which sends neither.
    ///
    /// Two shapes exist because the API changed under the older one: Claude 5 models reject
    /// `thinking.type.enabled` outright ("Use \"thinking.type.adaptive\" and
    /// \"output_config.effort\""), while 4.x models only understand the budget form. Both are
    /// kept rather than picking one, so a 4.5 model stays usable at effort.
    public var anthropicOutputEffort: String? {
        switch self {
        case .standard: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    /// Anthropic's thinking budget in tokens; `nil` for `.standard`, which omits the block
    /// entirely rather than sending a zero budget (the API rejects a budget below its minimum).
    ///
    /// Budgets, not model-specific guesses: the API requires `budget_tokens` < `max_tokens`, so
    /// these stay well under Side's 8192 ceiling and the ceiling is raised alongside them in
    /// `AnthropicMessagesProvider`.
    public var anthropicThinkingBudget: Int? {
        switch self {
        case .standard: return nil
        case .low: return 2_048
        case .medium: return 8_192
        case .high: return 16_384
        }
    }

    /// What OpenAI-shaped APIs call it. `nil` for `.standard` so the field is omitted — sending
    /// `reasoning_effort` to a model that doesn't reason is a 400 on some servers.
    public var openAIReasoningEffort: String? {
        switch self {
        case .standard: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    /// Extended thinking needs headroom for the thinking tokens *plus* the visible answer, and
    /// the API enforces `budget_tokens < max_tokens`.
    public func anthropicMaxTokens(base: Int) -> Int {
        guard let budget = anthropicThinkingBudget else { return base }
        return max(base, budget + 4_096)
    }
}
