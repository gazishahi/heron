import Foundation

/// Owns the persisted provider table and turns an entry + its Keychain credential into a
/// ready ChatModelProvider. App-level (one per machine, like UserDefaults), not per-project —
/// providers and keys are a machine-wide concern, unlike Tracks.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — same convention (and same reason) as LSPManager.
public final class ProviderRegistryStore: @unchecked Sendable {
    public static let shared = ProviderRegistryStore()

    public private(set) var providers: [ProviderDefinition] = []
    /// Which provider Think actually talks to — app-wide, not per-track (switching providers
    /// mid-project is a machine-level preference, same footing as the key itself). Defaults to
    /// the built-in Anthropic entry, which always exists.
    public private(set) var activeProviderId: String = "anthropic"
    private let storeURL: URL

    /// Resolution is deliberately a typed result, not an Optional — a missing credential must
    /// surface as "add your key in Preferences" in the UI, never as a provider that silently
    /// doesn't work.
    public enum AdapterResolution {
        case ready(ChatModelProvider, ProviderDefinition, ProviderModel)
        case missingAPIKey(ProviderDefinition)
        case unknownProvider
    }

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storeURL = support.appendingPathComponent("Side/providers.json")
        }
        load()
        if providers.isEmpty {
            providers = Self.builtInSeeds
            save()
        }
        mergeSeedModels()
        migrateLegacyDevKeyIfNeeded()
    }

    // MARK: - Keeping the model list current

    /// A built-in provider saved by an older build gains the models its seed has added since:
    /// the list was written once, on first launch, and never looked at again.
    private func mergeSeedModels() {
        var changed = false
        for seed in Self.builtInSeeds {
            guard let index = providers.firstIndex(where: { $0.id == seed.id }) else { continue }
            let merged = Self.merge(providers[index].models, adding: seed.models)
            if merged != providers[index].models { providers[index].models = merged; changed = true }
        }
        if changed { save() }
    }

    /// `adding` first, in its order (a provider lists newest first), then the ones only in
    /// `existing` (a model the person added, or one the provider has stopped listing but a
    /// track may still name). Names come from `adding`; context windows the person set stay.
    public static func merge(_ existing: [ProviderModel], adding fresh: [ProviderModel]) -> [ProviderModel] {
        var result: [ProviderModel] = fresh.map { model in
            guard let old = existing.first(where: { $0.id == model.id }) else { return model }
            return ProviderModel(id: model.id, displayName: model.displayName, contextWindowTokens: old.contextWindowTokens)
        }
        let freshIds = Set(fresh.map(\.id))
        result.append(contentsOf: existing.filter { !freshIds.contains($0.id) })
        return result
    }

    /// How often a provider's list is asked for, at most.
    public static let modelRefreshInterval: TimeInterval = 24 * 60 * 60
    private static func refreshedKey(_ id: String) -> String { "SideProviderModelsRefreshed.\(id)" }

    /// Asks the provider which models it offers now (Anthropic's `/v1/models`; a local
    /// server's `/v1/models`) and merges them in, so a new model shows without an update to
    /// Side. At most once a day unless `force` (a key was just saved). Needs the key the caller
    /// already has: this never reads the Keychain itself.
    public func refreshModels(providerId: String, apiKey: String?, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let definition = provider(for: providerId),
              definition.id == "anthropic" || definition.kind == .local else { completion?(false); return }
        let key = Self.refreshedKey(providerId)
        if !force, let last = HeronDefaults.store.object(forKey: key) as? Date, Date().timeIntervalSince(last) < Self.modelRefreshInterval {
            completion?(false)
            return
        }
        HeronDefaults.store.set(Date(), forKey: key)
        // Anthropic's base URL is the host; a local server's already ends in its API root
        // (`…/v1`, as chat/completions is appended to it), so its list is `models` under that.
        let path = definition.id == "anthropic" ? "v1/models" : "models"
        var request = URLRequest(url: definition.baseURL.appendingPathComponent(path).appending(queryItems: [URLQueryItem(name: "limit", value: "100")]))
        request.timeoutInterval = 15
        if definition.id == "anthropic" {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        Self.modelsSession.dataTask(with: request) { [weak self] data, response, _ in
            let fetched = (response as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(Self.parseModels) : nil
            DispatchQueue.main.async {
                guard let self, let fetched, !fetched.isEmpty, var current = self.provider(for: providerId) else {
                    // A failed ask is tried again next time rather than a day later.
                    if fetched == nil { HeronDefaults.store.removeObject(forKey: key) }
                    completion?(false)
                    return
                }
                let merged = Self.merge(current.models, adding: fetched)
                guard merged != current.models else { completion?(false); return }
                current.models = merged
                self.addOrUpdate(current)
                NotificationCenter.default.post(name: Self.modelsDidChangeNotification, object: self, userInfo: ["providerId": providerId])
                completion?(true)
            }
        }.resume()
    }

    /// Refuses redirects, as the streaming client does: `.shared` followed a 302 with the key
    /// header still on, and a loopback test delivered it to the second host (2026-09-30 audit,
    /// SEC-12). This runs unasked once a day, so it gets no session a caller could swap in.
    private static let modelsSession = URLSession(configuration: .default, delegate: SSEHTTPClient.RedirectRefuser(), delegateQueue: nil)

    public static let modelsDidChangeNotification = Notification.Name("SideProviderModelsDidChange")

    /// `{"data": [{"id", "display_name"?}]}`: Anthropic's shape and OpenAI's (whose entries
    /// have only an id).
    static func parseModels(_ data: Data) -> [ProviderModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let window = (entry["max_input_tokens"] as? Int) ?? (entry["context_window"] as? Int) ?? 200_000
            return ProviderModel(id: id, displayName: (entry["display_name"] as? String) ?? id, contextWindowTokens: window)
        }
    }

    public static let builtInSeeds: [ProviderDefinition] = [
        ProviderDefinition(
            id: "anthropic",
            displayName: "Anthropic",
            kind: .builtIn,
            baseURL: URL(string: "https://api.anthropic.com")!,
            requiresAPIKey: true,
            models: [
                ProviderModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-fable-5-1", displayName: "Claude Fable 5.1", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-opus-5", displayName: "Claude Opus 5", contextWindowTokens: 200_000),
                ProviderModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", contextWindowTokens: 200_000),
            ],
            defaultModelId: "claude-sonnet-5"
        ),
    ]

    public func provider(for id: String) -> ProviderDefinition? {
        providers.first { $0.id == id }
    }

    public func addOrUpdate(_ provider: ProviderDefinition) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    public func setDefaultModel(providerId: String, modelId: String) {
        guard var definition = provider(for: providerId),
              definition.models.contains(where: { $0.id == modelId }) else { return }
        definition.defaultModelId = modelId
        addOrUpdate(definition)
    }

    public func setActiveProvider(_ id: String) {
        guard provider(for: id) != nil else { return }
        activeProviderId = id
        save()
    }

    public func removeProvider(_ id: String) {
        guard id != "anthropic" else { return } // the one provider that must always exist
        providers.removeAll { $0.id == id }
        if activeProviderId == id { activeProviderId = "anthropic" }
        save()
    }

    /// `modelId` selects a specific model within the provider — a track's own choice. It falls
    /// back to the provider's default rather than failing when the named model is gone (removed
    /// from a BYOK provider, renamed upstream): a stale selection shouldn't brick a track's
    /// conversation, and the header shows what actually resolved.
    public func resolveAdapter(providerId: String, modelId: String? = nil, effort: AgentEffort = .standard) -> AdapterResolution {
        guard let definition = provider(for: providerId) else { return .unknownProvider }
        guard let model = modelId.flatMap({ requested in definition.models.first { $0.id == requested } })
            ?? definition.models.first(where: { $0.id == definition.defaultModelId })
            ?? definition.models.first
        else {
            return .unknownProvider
        }
        // Env var checked *before* Keychain, not just as a fallback after it — a Keychain read
        // triggers a real ACL permission prompt (macOS ties the grant to the app's code
        // signature, which an ad-hoc-signed debug build gets a fresh one of on every rebuild, so
        // this would otherwise re-prompt on every single relaunch during development). With
        // ANTHROPIC_API_KEY set, there's no reason to ever touch the Keychain at all — checking
        // it first means the prompt genuinely never fires as long as the env var is present, not
        // just "recovers gracefully after" one already did.
        var apiKey: String?
        if definition.id == "anthropic" {
            apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        // Only touch the Keychain at all when this provider actually needs a key and nothing
        // above already resolved one — a local server that never asked for a key shouldn't
        // trigger a Keychain ACL prompt just because it happens to be the active provider.
        if apiKey?.isEmpty != false, definition.requiresAPIKey {
            apiKey = KeychainStore.get(account: definition.id)
        }
        if definition.requiresAPIKey, apiKey?.isEmpty != false {
            return .missingAPIKey(definition)
        }
        switch definition.kind {
        case .builtIn where definition.id == "anthropic":
            refreshModels(providerId: definition.id, apiKey: apiKey)
            return .ready(
                AnthropicMessagesProvider(apiKey: apiKey ?? "", modelId: model.id, baseURL: definition.baseURL, effort: effort),
                definition, model
            )
        case .builtIn:
            return .unknownProvider // no other builtIn ids are modeled yet
        case .byokOpenAICompatible, .local:
            // Covers OpenAI BYOK and local servers (Ollama, LM Studio) alike — both speak the
            // same chat-completions wire shape, so one adapter serves both `kind`s.
            return .ready(
                OpenAICompatibleChatProvider(
                    apiKey: apiKey, modelId: model.id, baseURL: definition.baseURL,
                    contextWindowTokens: model.contextWindowTokens, effort: effort,
                    asksForStreamUsage: definition.kind == .byokOpenAICompatible
                ),
                definition, model
            )
        }
    }

    // MARK: - Persistence (TrackStore's conventions: .iso8601, .prettyPrinted, try?-swallowed)

    /// Wraps `providers` + `activeProviderId` together so both persist in one file. Decodes the
    /// pre-BYOK bare-array shape as a fallback, the same pattern `AgentSessionStore` uses for its
    /// own persisted format — a file written before this field existed shouldn't need a migration
    /// step, just a default.
    private struct RegistryState: Codable {
        public var providers: [ProviderDefinition]
        public var activeProviderId: String

        public init(providers: [ProviderDefinition], activeProviderId: String) {
            self.providers = providers
            self.activeProviderId = activeProviderId
        }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let providers = try? container.decode([ProviderDefinition].self, forKey: .providers) {
                self.providers = providers
                self.activeProviderId = (try? container.decode(String.self, forKey: .activeProviderId)) ?? "anthropic"
            } else {
                self.providers = (try? [ProviderDefinition](from: decoder)) ?? []
                self.activeProviderId = "anthropic"
            }
        }
    }

    private func load() {
        guard let state = JSONStore.read(RegistryState.self, from: storeURL)?.payload else { return }
        providers = state.providers
        activeProviderId = state.activeProviderId
    }

    private func save() {
        JSONStore.write(RegistryState(providers: providers, activeProviderId: activeProviderId), to: storeURL)
    }

    /// Phase 1 stored a dev key in UserDefaults; anyone who set it up that way shouldn't have
    /// their working configuration silently break when Keychain storage lands — move the key
    /// over once, then remove the old one.
    /// Runs on every launch, so the `UserDefaults` check — free, no Keychain access — comes
    /// first: there's a real legacy key to migrate on essentially no launches at this point, and
    /// `KeychainStore.hasSecret` triggers a genuine Keychain ACL prompt, which used to mean this
    /// one check alone re-prompted on every single relaunch regardless of anything else touching
    /// the Keychain that session.
    private func migrateLegacyDevKeyIfNeeded() {
        let legacyKey = "side.dev.anthropic-api-key"
        guard let legacy = HeronDefaults.store.string(forKey: legacyKey), !legacy.isEmpty,
              !KeychainStore.hasSecret(account: "anthropic") else { return }
        if KeychainStore.set(secret: legacy, account: "anthropic") {
            HeronDefaults.store.removeObject(forKey: legacyKey)
        }
    }
}
