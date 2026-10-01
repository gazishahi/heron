import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case builtIn
    /// A user-added provider speaking the OpenAI-compatible chat-completions wire shape —
    /// covers OpenAI BYOK and most local servers (Ollama, LM Studio). Adapter lands in
    /// Phase 6; the kind exists now so the persisted format doesn't need a migration then.
    case byokOpenAICompatible
    case local
}

public struct ProviderModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var contextWindowTokens: Int

    public init(id: String, displayName: String, contextWindowTokens: Int) {
        self.id = id
        self.displayName = displayName
        self.contextWindowTokens = contextWindowTokens
    }
}

/// One entry in the provider registry — the mutable, persisted analog of
/// LanguageServerRegistry.Entry. Custom/local providers flow through this exact same struct;
/// there is deliberately no special-casing of how a provider got here.
public struct ProviderDefinition: Codable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public let kind: ProviderKind
    public var baseURL: URL
    public var requiresAPIKey: Bool
    public var models: [ProviderModel]
    public var defaultModelId: String

    public init(id: String, displayName: String, kind: ProviderKind, baseURL: URL, requiresAPIKey: Bool, models: [ProviderModel], defaultModelId: String) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
        self.models = models
        self.defaultModelId = defaultModelId
    }
}
