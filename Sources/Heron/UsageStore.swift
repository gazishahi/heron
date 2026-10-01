import Foundation

/// What one (project, track, provider, model) combination has cost so far, in tokens.
public struct UsageTotals: Codable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    /// Prompt tokens served from the provider's cache — counted separately because they're
    /// billed differently (and much cheaper) than fresh input.
    public var cachedInputTokens: Int = 0
    /// Prompt tokens written to the provider's cache (billed above fresh input, once).
    public var cacheWriteInputTokens: Int = 0
    /// Model turns, not user messages: one agent reply that makes three tool round-trips is
    /// three requests, and each one is billed.
    public var requestCount: Int = 0

    public var totalTokens: Int { inputTokens + outputTokens + cachedInputTokens + cacheWriteInputTokens }

    public mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteInputTokens += other.cacheWriteInputTokens
        requestCount += other.requestCount
    }

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, cacheWriteInputTokens: Int = 0, requestCount: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.requestCount = requestCount
    }

    private enum CodingKeys: String, CodingKey { case inputTokens, outputTokens, cachedInputTokens, cacheWriteInputTokens, requestCount }

    /// Tolerant: rows written before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheWriteInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteInputTokens) ?? 0
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
    }
}

/// One aggregate row. Deliberately an aggregate rather than an event log: the ask was visibility,
/// not an audit trail, and per-request events would grow without bound — re-creating the very
/// memory problem `AgentSessionStore` was just restructured to avoid.
public struct UsageRecord: Codable, Equatable {
    public let projectPath: String
    public let trackKey: String
    public let providerId: String
    public let modelId: String
    /// Calendar month this row accumulates in, `yyyy-MM`. Part of the row's identity, which is
    /// what makes a monthly budget answerable at all — the alternative (one row per request)
    /// grows without bound. `""` on rows written before budgets existed: those still count
    /// toward all-time totals but can't be attributed to a month, so they're left out of
    /// monthly ones rather than silently inflating the current month.
    public var periodKey: String
    public var totals: UsageTotals
    public var lastUsedAt: Date

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public init(projectPath: String, trackKey: String, providerId: String, modelId: String, periodKey: String, totals: UsageTotals, lastUsedAt: Date) {
        self.projectPath = projectPath
        self.trackKey = trackKey
        self.providerId = providerId
        self.modelId = modelId
        self.periodKey = periodKey
        self.totals = totals
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectPath, trackKey, providerId, modelId, periodKey, totals, lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        trackKey = try container.decode(String.self, forKey: .trackKey)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        periodKey = try container.decodeIfPresent(String.self, forKey: .periodKey) ?? ""
        totals = try container.decodeIfPresent(UsageTotals.self, forKey: .totals) ?? UsageTotals()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? Date()
    }

    /// `yyyy-MM` in the user's own calendar — a budget is a human, local-time notion of "this
    /// month," not a UTC one.
    public static func periodKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
}

/// Token accounting across every project. Providers already report usage at the end of each
/// streamed turn and `AgentRunner` used to drop it on the floor, so a run's cost was invisible:
/// no per-track total, no per-model total, no way to notice a tool loop burning tokens.
///
/// App-wide rather than per-project (unlike the session store) because the question it answers —
/// "what have I spent?" — is asked in Preferences, which isn't scoped to an open project.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main thread —
/// same convention (and same reason) as `ProviderRegistryStore`.
public final class UsageStore: @unchecked Sendable {
    /// Under XCTest, a private file: tests record real-looking runs, and they used to land in the
    /// user's own usage (dozens of "custom-…" agents from mock projects).
    public static let shared = UsageStore(storeURL: isTesting
        ? FileManager.default.temporaryDirectory.appendingPathComponent("side-usage-tests-\(ProcessInfo.processInfo.processIdentifier).json")
        : nil)

    static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil }

    public private(set) var records: [UsageRecord] = []
    private let storeURL: URL
    private var changeObservers: [UUID: () -> Void] = [:]

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storeURL = support.appendingPathComponent("Side/usage.json")
        }
        JSONStore.flushPendingWrites()
        load()
    }

    @discardableResult
    public func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    public func removeChangeObserver(_ token: UUID) { changeObservers.removeValue(forKey: token) }

    public func record(projectPath: String, trackKey: String, providerId: String, modelId: String, usage: TokenUsage, now: Date = Date()) {
        var incoming = UsageTotals()
        incoming.inputTokens = usage.inputTokens
        incoming.outputTokens = usage.outputTokens
        incoming.cachedInputTokens = usage.cachedInputTokens ?? 0
        incoming.cacheWriteInputTokens = usage.cacheWriteInputTokens ?? 0
        incoming.requestCount = 1

        let period = UsageRecord.periodKey(for: now)
        if let index = records.firstIndex(where: {
            $0.projectPath == projectPath && $0.trackKey == trackKey && $0.providerId == providerId
                && $0.modelId == modelId && $0.periodKey == period
        }) {
            records[index].totals.add(incoming)
            records[index].lastUsedAt = now
        } else {
            records.append(UsageRecord(
                projectPath: projectPath, trackKey: trackKey, providerId: providerId,
                modelId: modelId, periodKey: period, totals: incoming, lastUsedAt: now
            ))
        }
        save()
        notifyObservers()
    }

    /// Estimated spend inside one calendar month, and whether an unpriced model contributed
    /// tokens to it — a budget can only be enforced against the priced part, and the caller has
    /// to be able to say so rather than implying the figure is complete.
    public func estimatedCost(inPeriod period: String) -> (total: Double, hasUnpricedModels: Bool) {
        var total = 0.0
        var hasUnpriced = false
        for record in records where record.periodKey == period {
            if let cost = ModelPricing.estimatedCost(modelId: record.modelId, totals: record.totals) {
                total += cost
            } else if record.totals.totalTokens > 0 {
                hasUnpriced = true
            }
        }
        return (total, hasUnpriced)
    }

    public func estimatedCostThisMonth(now: Date = Date()) -> (total: Double, hasUnpricedModels: Bool) {
        estimatedCost(inPeriod: UsageRecord.periodKey(for: now))
    }

    public func totals(projectPath: String, trackKey: String) -> UsageTotals {
        records
            .filter { $0.projectPath == projectPath && $0.trackKey == trackKey }
            .reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// Rolled up per model, biggest spender first — the shape Preferences lists.
    public func totalsByModel() -> [(providerId: String, modelId: String, totals: UsageTotals, lastUsedAt: Date)] {
        var grouped: [String: (providerId: String, modelId: String, totals: UsageTotals, lastUsedAt: Date)] = [:]
        for record in records {
            let key = "\(record.providerId)|\(record.modelId)"
            var entry = grouped[key] ?? (record.providerId, record.modelId, UsageTotals(), record.lastUsedAt)
            entry.totals.add(record.totals)
            entry.lastUsedAt = max(entry.lastUsedAt, record.lastUsedAt)
            grouped[key] = entry
        }
        return grouped.values.sorted {
            let left = ModelPricing.estimatedCost(modelId: $0.modelId, totals: $0.totals) ?? 0
            let right = ModelPricing.estimatedCost(modelId: $1.modelId, totals: $1.totals) ?? 0
            if left != right { return left > right }
            return $0.totals.totalTokens > $1.totals.totalTokens
        }
    }

    public func totalsByProject() -> [(projectPath: String, totals: UsageTotals, lastUsedAt: Date)] {
        var grouped: [String: (projectPath: String, totals: UsageTotals, lastUsedAt: Date)] = [:]
        for record in records {
            var entry = grouped[record.projectPath] ?? (record.projectPath, UsageTotals(), record.lastUsedAt)
            entry.totals.add(record.totals)
            entry.lastUsedAt = max(entry.lastUsedAt, record.lastUsedAt)
            grouped[record.projectPath] = entry
        }
        return grouped.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func grandTotal() -> UsageTotals {
        records.reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// Sum of the per-model estimates, plus whether any model in the mix has no published price
    /// here — the caller needs that flag to avoid presenting a partial figure as a complete one.
    public func estimatedCost() -> (total: Double, hasUnpricedModels: Bool) {
        var total = 0.0
        var hasUnpriced = false
        for entry in totalsByModel() {
            if let cost = ModelPricing.estimatedCost(modelId: entry.modelId, totals: entry.totals) {
                total += cost
            } else if entry.totals.totalTokens > 0 {
                hasUnpriced = true
            }
        }
        return (total, hasUnpriced)
    }

    /// Dropped alongside a track's conversation and checkpoints — same cleanup contract.
    public func removeUsage(projectPath: String, trackKey: String) {
        records.removeAll { $0.projectPath == projectPath && $0.trackKey == trackKey }
        save()
        notifyObservers()
    }

    public func removeAll() {
        records = []
        save()
        notifyObservers()
    }

    private func notifyObservers() {
        for observer in changeObservers.values { observer() }
    }

    private func load() {
        records = JSONStore.read([UsageRecord].self, from: storeURL)?.payload ?? []
        // Runs in the temporary directory are test projects (see `shared`), never the user's:
        // drop what earlier test runs left behind.
        let kept = records.filter { !Self.isTemporary($0.projectPath) }
        if kept.count != records.count, !Self.isTesting {
            records = kept
            save()
        }
    }

    static func isTemporary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return resolved.hasPrefix(temp) || resolved.hasPrefix("/private/var/folders/") || resolved.hasPrefix("/private/tmp/")
    }

    /// A moment later, compact, once for a burst of requests (D7: every round trip rewrote it).
    /// The monthly budget reads the records in memory, so it never waits on this.
    private func save() {
        JSONStore.writeSoon(to: storeURL) { self.records }
    }
}

/// Rough per-million-token prices, used only to turn token counts into a sense of scale.
///
/// Deliberately conservative about what it claims: a model with no entry here shows tokens and no
/// cost rather than a guess, and every figure is labelled an estimate wherever it's shown.
/// Published prices change, and a confidently wrong number is worse than an honest blank.
public enum ModelPricing {
    /// Per million tokens, in USD.
    public struct Price: Sendable, Equatable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double
        /// A cache hit: 0.1x input on most models, less on some (0.05x Opus 5.5, 0.025x Fable 5.1).
        public let cachedInputPerMillion: Double
        /// A 5-minute cache write: 1.25x input.
        public let cacheWritePerMillion: Double

        public init(inputPerMillion: Double, outputPerMillion: Double, cachedInputPerMillion: Double? = nil, cacheWritePerMillion: Double? = nil) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion ?? inputPerMillion * 0.1
            self.cacheWritePerMillion = cacheWritePerMillion ?? inputPerMillion * 1.25
        }
    }

    /// Anthropic's published prices (platform.claude.com/docs/en/about-claude/pricing, read
    /// 2026-09-26). Every model the registry seeds has a row; a test holds that.
    static let table: [String: Price] = [
        "claude-fable-5-1": Price(inputPerMillion: 10, outputPerMillion: 50, cachedInputPerMillion: 0.25),
        "claude-opus-5-5": Price(inputPerMillion: 4, outputPerMillion: 20, cachedInputPerMillion: 0.20),
        "claude-opus-5": Price(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-5": Price(inputPerMillion: 2, outputPerMillion: 10),
        "claude-haiku-4-5": Price(inputPerMillion: 1, outputPerMillion: 5),
        // Earlier models the Models API lists, which the picker can offer after a refresh; the
        // same page's prices. Unpriced, a model's spend was invisible to the budget (2026-09-30
        // audit, H11).
        "claude-fable-5": Price(inputPerMillion: 10, outputPerMillion: 50),
        "claude-mythos-5-1": Price(inputPerMillion: 10, outputPerMillion: 50, cachedInputPerMillion: 0.25),
        "claude-opus-4-8": Price(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-7": Price(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-6": Price(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-4-6": Price(inputPerMillion: 3, outputPerMillion: 15),
    ]

    /// A model's row: its id exactly, or a family's with a date or a variant after it
    /// (`claude-haiku-4-5-20251001`, `claude-opus-5[1m]`). Only those shapes, so a future
    /// `claude-opus-5-9` isn't priced as `claude-opus-5`.
    static func key(for modelId: String) -> String? {
        if table[modelId] != nil { return modelId }
        return table.keys.filter { key in
            guard modelId.hasPrefix(key) else { return false }
            let rest = modelId.dropFirst(key.count)
            let isDate = rest.count == 9 && rest.first == "-" && rest.dropFirst().allSatisfy(\.isNumber)
            let isVariant = rest.hasPrefix("[") && rest.hasSuffix("]")
            return isDate || isVariant
        }.max { $0.count < $1.count }
    }

    public static func price(modelId: String) -> Price? { key(for: modelId).flatMap { table[$0] } }

    /// `nil` when the model isn't priced here — a local model costs nothing, and an unknown
    /// remote one shouldn't be guessed at.
    public static func estimatedCost(modelId: String, totals: UsageTotals) -> Double? {
        guard let price = price(modelId: modelId) else { return nil }
        return Double(totals.inputTokens) / 1_000_000 * price.inputPerMillion
            + Double(totals.outputTokens) / 1_000_000 * price.outputPerMillion
            + Double(totals.cachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
            + Double(totals.cacheWriteInputTokens) / 1_000_000 * price.cacheWritePerMillion
    }

    /// One request's cost.
    public static func estimatedCost(modelId: String, usage: TokenUsage) -> Double? {
        estimatedCost(modelId: modelId, totals: UsageTotals(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                                                            cachedInputTokens: usage.cachedInputTokens ?? 0,
                                                            cacheWriteInputTokens: usage.cacheWriteInputTokens ?? 0, requestCount: 1))
    }

    /// What the cached part would have cost at the full price, less what it did cost: the saving.
    public static func cacheSaving(modelId: String, totals: UsageTotals) -> Double? {
        guard let price = price(modelId: modelId) else { return nil }
        return Double(totals.cachedInputTokens) / 1_000_000 * (price.inputPerMillion - price.cachedInputPerMillion)
            - Double(totals.cacheWriteInputTokens) / 1_000_000 * (price.cacheWritePerMillion - price.inputPerMillion)
    }

    public static func isPriced(modelId: String) -> Bool { price(modelId: modelId) != nil }
}

/// Shared formatting so a token count reads the same in Think's header and in Preferences.
public enum UsageFormatting {
    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        default: return String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    public static func cost(_ amount: Double) -> String {
        amount > 0 && amount < 0.01 ? "<$0.01" : String(format: "$%.2f", amount)
    }
}
