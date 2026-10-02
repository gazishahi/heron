import Foundation

private final class WeakHarness: @unchecked Sendable {
    weak var value: ACPHarness?
    init(_ value: ACPHarness) { self.value = value }
}

/// A track's conversation run by an outside agent over the Agent Client Protocol
/// (`SIDE_RFC_BYO_HARNESS.md`). The agent's replies, reasoning and tool activity stream into the
/// same transcript Heron fills; its permission prompts become cards (step 2).
///
/// Step 3 offers the agent Side's files and terminals:
/// - **Reads** (`fs/read_text_file`) are contained to the worktree and see unsaved buffers; what
///   was served is remembered as that file's base.
/// - **Writes** (`fs/write_text_file`) go through `ProposedEditApplier`. One approval per edit
///   (D9): a write the user already allowed through the agent's permission card applies without
///   a second card; an unannounced write follows the track's autonomy exactly as Heron's edits
///   do — Full applies, Manual and Guarded show a card. A write whose base moved is refused.
/// - **Terminals** (`terminal/*`) are their own Run tabs (`ACPTerminalHost`).
/// - **Every turn that changed files ends in a checkpoint**, however the files were written —
///   staging what the agent touched plus what newly became dirty, minus what the user saved
///   during the turn (`UserSaveLog`).
@MainActor
public final class ACPHarness: Harness {
    public let trackKey: String
    public let agent: ACPAgent
    public var harnessName: String? { agent.displayName }

    public private(set) var entries: [RunTranscriptEntry] = []
    public private(set) var phase: AgentRunPhase = .idle
    public private(set) var needsYouSince: Date?
    public var activity: AgentActivity { AgentActivity(phase: phase, hasUnseenCompletion: hasUnseenCompletion) }
    public var hasCommandAwaitingApproval: Bool { !pendingPermissions.isEmpty || !pendingWrites.isEmpty || !pendingSpawnApprovals.isEmpty }
    public var appliedEditCounts: [(path: String, added: Int, removed: Int)] {
        appliedCounts.map { (path: $0.key, added: $0.value.added, removed: $0.value.removed) }.sorted { $0.path < $1.path }
    }
    /// Past conversations with this agent on this track (filed by New Conversation).
    public var archivedConversations: [ArchivedConversation] {
        sessionStore?.outsideArchives(trackKey: trackKey, agentId: agent.id) ?? []
    }
    public var runningUserTaskName: String? { nil }
    public var pendingUserTaskProposalId: UUID? { nil }

    /// Readiness is only known once the agent has been looked for, which takes a login-shell
    /// spawn; until a launch fails, sending is allowed and a missing agent is reported inline.
    public var isReadyToSend: Bool { true }
    public var notReadyReason: String { "" }

    private let launchProvider: @Sendable () -> ACPLaunch?
    private let rootProvider: () -> URL
    private let bridgeProvider: () -> WorkspaceBridge
    private let modeProvider: () -> AgentMode
    private let sessionStore: AgentSessionStore?
    private let terminalHostProvider: () -> ACPTerminalHost?
    /// Identifies this harness's terminals to the host, so Stop ends exactly these.
    private let ownerId = UUID()
    /// Files a checkpoint under this conversation — an outside session has no `AgentSession`.
    private var conversationId = UUID()
    private var observers: [UUID: (AgentRunEvent) -> Void] = [:]
    private var hasUnseenCompletion = false
    private var connection: ACPConnection?
    private var sessionId: String?
    private var streamingIndex: Int?
    private var thinkingIndex: Int?
    private var toolEntryIndex: [String: Int] = [:]
    /// Permission cards waiting for an answer: entry id → the agent's request, and the files its
    /// tool call names (a write to one of them, once allowed, needs no second card — D9).
    private struct PendingPermission { let requestId: Any; let paths: Set<String> }
    private var pendingPermissions: [UUID: PendingPermission] = [:]
    /// Edit cards for unannounced writes, waiting on Apply/Reject: entry id → request and edit.
    private var pendingWrites: [UUID: (requestId: Any, edit: ProposedEdit)] = [:]
    /// Absolute paths the user allowed the agent to change, through its own permission card.
    private var grantedPaths: Set<String> = []
    /// Absolute path → the content the agent was last shown (a read, or a diff's `oldText`) —
    /// the base a later write must still match.
    private var bases: [String: String] = [:]
    /// Tool call id → its kind and the absolute paths it names.
    private var toolCalls: [String: (kind: String?, paths: Set<String>)] = [:]
    // The turn in flight, for its checkpoint.
    private var turnBaseline: Set<String>?
    /// The turn's baseline couldn't be read (git status failed): see `stageAndCommit`.
    private var turnBaselineUnknown = false
    private var turnStartedAt = Date()
    /// Worktree-relative paths the agent is known to have changed this turn.
    private var turnTouched: Set<String> = []
    private var turnCommands: [String] = []
    private var turnPrompt = ""
    private var appliedCounts: [String: (added: Int, removed: Int)] = [:]
    private var usage: (used: Int, size: Int)?
    /// The agent's own settings — model, effort, mode — from its session (plan step 4, D6).
    public private(set) var agentOptions: [HarnessOption] = []
    /// How each option is changed: ACP `configOptions` are set with `session/set_config_option`;
    /// agents that predate them use `session/set_mode` / `session/set_model`.
    enum OptionBacking: Equatable { case config, mode, model }
    private var optionBacking: [String: OptionBacking] = [:]
    /// The account the agent reports (`_auth/status_update`) — which one pays matters.
    public private(set) var accountLabel: String?
    /// The track's remembered choices (option id → value), re-applied to each new session.
    private let preferredOptions: () -> [String: String]
    private let onOptionChanged: (String, String) -> Void
    // Durability (plan step 5): Side's own record, and the agent's session to reopen.
    private var logURL: URL? { sessionStore?.outsideLogURL(trackKey: trackKey, agentId: agent.id) }
    /// Entries already in the record; everything after is written when it's final.
    private var persistedCount = 0
    private var headerWritten = false
    /// The agent's session this conversation last ran in, to reopen with `session/load`.
    private var storedAgentSessionId: String?
    /// The agent said it can reopen a session (`agentCapabilities.loadSession`).
    private var agentCanLoadSession = false
    /// While the agent replays a reopened session's history: Side's record already shows it.
    private var replaying = false
    // Side's tools for the agent over MCP (multi-agent RFC step 1).
    private let toolServer: SideToolServer?
    private let trackContext: @MainActor @Sendable () -> [AgentTrackSummary]
    private var toolServerRegistration: (url: URL, token: String)?
    private let coordinatorProvider: () -> (any TrackCoordinating)?
    /// The project this conversation's tokens are filed under (Settings › Usage).
    private let usageProjectPath: String?
    /// Side's own approval cards for a coordinator's spawns (M1), by entry id.
    private var pendingSpawnApprovals: [UUID: @Sendable (Bool) -> Void] = [:]
    /// When the user last allowed a coordinator tool call (`create_subtrack`,
    /// `promote_subtrack`) on the agent's own permission card: that approval covers Side's too
    /// (D9, one approval per action).
    private var coordinatorGrants: [String: Date] = [:]
    /// The agent accepts MCP servers over HTTP (`agentCapabilities.mcpCapabilities.http`).
    private var agentTakesHTTPTools = false
    /// The PATH the agent runs with, to resolve the user's MCP server commands against.
    private var launchSearchPath: String?
    /// How the agent was asked to sign in (Settings › Agents), for agents that ask.
    private var signIn: ACPAgent.SignIn = .subscription
    /// Sends waiting for the session that's being opened (by a send, or by `prepareSession`).
    private var sessionWaiters: [(String) -> Void] = []
    /// Fires when a turn has gone silent too long (`stallInterval`).
    private lazy var stallWatchdog = Watchdog(interval: { [weak self] in self?.stallInterval ?? 180 }, fire: { [weak self] in self?.stallFired() })
    /// `terminal/wait_for_exit` calls still waiting on a command — silence then is a command
    /// running, not a hang.
    private var waitingOnTerminals = 0
    /// Longer than Heron's 90 s: an outside agent can think or run its own tools without
    /// streaming anything for a while.
    var stallInterval: TimeInterval = 180
    /// The agent is being found and launched; a second send waits for that to finish.
    private var starting = false

    public init(trackKey: String, agent: ACPAgent, launchProvider: @escaping @Sendable () -> ACPLaunch?, rootProvider: @escaping () -> URL,
                bridgeProvider: @escaping () -> WorkspaceBridge = { .none }, modeProvider: @escaping () -> AgentMode = { .default },
                sessionStore: AgentSessionStore? = nil, terminalHost: @escaping () -> ACPTerminalHost? = { nil },
                preferredOptions: @escaping () -> [String: String] = { [:] }, onOptionChanged: @escaping (String, String) -> Void = { _, _ in },
                toolServer: SideToolServer? = nil, trackContext: @escaping @MainActor @Sendable () -> [AgentTrackSummary] = { [] },
                coordinatorProvider: @escaping () -> (any TrackCoordinating)? = { nil }, usageProjectPath: String? = nil) {
        self.trackKey = trackKey
        self.agent = agent
        self.launchProvider = launchProvider
        self.rootProvider = rootProvider
        self.bridgeProvider = bridgeProvider
        self.modeProvider = modeProvider
        self.sessionStore = sessionStore
        self.terminalHostProvider = terminalHost
        self.preferredOptions = preferredOptions
        self.onOptionChanged = onOptionChanged
        self.toolServer = toolServer
        self.trackContext = trackContext
        self.coordinatorProvider = coordinatorProvider
        self.usageProjectPath = usageProjectPath
        agentOptions = seededOptions()
        restoreFromLog()
    }

    // MARK: The record (plan step 5)

    /// The conversation as Side last showed it, so a relaunch (or the track being shown again)
    /// brings it back rather than an empty Think.
    private func restoreFromLog() {
        guard let url = logURL else { return }
        let contents = OutsideSessionLog.read(url)
        guard contents.conversationId != nil || !contents.entries.isEmpty else { return }
        entries = contents.entries
        persistedCount = entries.count
        headerWritten = true
        if let id = contents.conversationId { conversationId = id }
        storedAgentSessionId = contents.agentSessionId
        // The changes pill: what this conversation's checkpoints changed.
        for checkpoint in sessionStore?.checkpoints(forTrackKey: trackKey) ?? [] where checkpoint.agentSessionId == conversationId {
            for change in checkpoint.fileChanges {
                let existing = appliedCounts[change.path] ?? (0, 0)
                appliedCounts[change.path] = (existing.added + change.added, existing.removed + change.removed)
            }
        }
    }

    /// Appends every finished entry not yet in the record. Stops at a card still waiting for an
    /// answer: it's written once decided.
    private func persistNewEntries() {
        guard let url = logURL else { return }
        var records: [OutsideSessionLog.Record] = []
        if !headerWritten {
            records.append(.init(kind: .header, conversationId: conversationId, agentId: agent.id, agentSessionId: sessionId))
            headerWritten = true
        }
        while persistedCount < entries.count {
            let entry = entries[persistedCount]
            switch entry.kind {
            case .permissionRequest(let p) where p.chosenOptionName == nil: break
            case .proposal(let p) where p.resolution == nil: break
            default:
                if let record = OutsideSessionLog.record(for: entry) { records.append(record) }
                persistedCount += 1
                continue
            }
            break
        }
        OutsideSessionLog.append(records, to: url)
    }

    /// The agent's session id, recorded so the next launch can reopen it.
    private func recordAgentSession(_ id: String) {
        guard id != storedAgentSessionId else { return }
        storedAgentSessionId = id
        guard let url = logURL else { return }
        persistNewEntries() // the header first, if this is a new record
        OutsideSessionLog.append([.init(kind: .header, conversationId: conversationId, agentSessionId: id)], to: url)
    }

    // MARK: Last-known settings

    /// The agent's settings as last seen (any track), with this track's remembered choices on
    /// top — so the pill can say "Claude Code · Opus 5.5" the moment a track is shown, before the
    /// agent has started. Replaced by the real list as soon as a session opens.
    private var knownOptionsKey: String { "SideACPKnownOptions.\(agent.id)" }

    private func seededOptions() -> [HarnessOption] {
        guard let data = HeronDefaults.store.data(forKey: knownOptionsKey),
              var options = try? JSONDecoder().decode([HarnessOption].self, from: data) else { return [] }
        let preferred = preferredOptions()
        for index in options.indices {
            if let value = preferred[options[index].id], options[index].choices.contains(where: { $0.value == value }) {
                options[index].current = value
            }
        }
        return options
    }

    private func rememberKnownOptions() {
        guard !agentOptions.isEmpty, let data = try? JSONEncoder().encode(agentOptions) else { return }
        HeronDefaults.store.set(data, forKey: knownOptionsKey)
    }

    // MARK: Observation

    @discardableResult
    public func addObserver(_ observer: @escaping (AgentRunEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func notify(_ event: AgentRunEvent) { for observer in observers.values { observer(event) } }

    private func setPhase(_ newPhase: AgentRunPhase) {
        guard phase != newPhase else { return }
        let wasNeedsYou = activity == .needsYou
        phase = newPhase
        // Waiting on the user isn't the agent hanging.
        if newPhase == .awaitingApproval { disarmStallTimer() } else if newPhase == .streaming || newPhase == .runningTools { armStallTimer() }
        let isNeedsYou = activity == .needsYou
        if isNeedsYou, !wasNeedsYou { needsYouSince = Date() } else if !isNeedsYou { needsYouSince = nil }
        notify(.phaseChanged)
    }

    @discardableResult
    private func append(_ kind: RunTranscriptEntry.Kind) -> Int {
        entries.append(RunTranscriptEntry(kind: kind))
        let index = entries.count - 1
        notify(.appended(index))
        return index
    }

    private func replace(_ index: Int, _ kind: RunTranscriptEntry.Kind) {
        guard entries.indices.contains(index) else { return }
        entries[index].kind = kind
        notify(.updated(index))
    }

    // MARK: Sending

    public func send(_ text: String, attachments: [AgentImageAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phase.isBusy else { return }
        // The monthly budget stops outside agents too (2026-09-30 audit, H11: they kept spending
        // after Heron stopped). Their own spend can't be priced, which the message says.
        if case .exceeded(let spent, let limit) = UsageBudget.status() {
            append(.userText(trimmed))
            append(.failure(UsageBudget.blockedMessageForOutsideAgent(spent: spent, limit: limit)))
            persistNewEntries()
            setPhase(.blocked(.budgetReached))
            return
        }
        append(.userText(trimmed))
        persistNewEntries()
        streamingIndex = nil
        thinkingIndex = nil
        setPhase(.streaming)
        turnPrompt = trimmed
        turnTouched = []
        turnCommands = []
        turnStartedAt = Date()
        grantedPaths = []
        // What was already dirty before the agent starts — the checkpoint won't claim it. One
        // git spawn, off the main thread, before the prompt goes out.
        let root = rootProvider().path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let baseline = GitPaths.dirtyPaths(cwd: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.turnBaseline = baseline ?? []
                    self.turnBaselineUnknown = baseline == nil
                    self.withSession { [weak self] sessionId in
                        self?.prompt(trimmed, sessionId: sessionId)
                    }
                }
            }
        }
    }

    private func prompt(_ text: String, sessionId: String) {
        armStallTimer()
        connection?.request("session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let stopReason = (value as? [String: Any])?["stopReason"] as? String ?? "end_turn"
                self.recordUsage((value as? [String: Any])?["usage"] as? [String: Any])
                self.finishTurn(stopReason: stopReason)
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    /// The turn's tokens, filed like Heron's so a track's (and a coordinator's) spend adds up
    /// across agents. Model is the agent's own id for it ("opus[1m]"); Side has no price for
    /// those, so spend shows as tokens.
    private func recordUsage(_ usage: [String: Any]?) {
        guard let usage, let projectPath = usageProjectPath else { return }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let input = int("inputTokens"), output = int("outputTokens"), cached = int("cachedReadTokens")
        guard input + output + cached > 0 else { return }
        let model = agentOptions.first { $0.category == .model }?.current ?? agent.id
        UsageStore.shared.record(projectPath: projectPath, trackKey: trackKey, providerId: "acp:\(agent.id)", modelId: model,
                                 usage: TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached))
    }

    private func finishTurn(stopReason: String) {
        disarmStallTimer()
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The turn ended before this edit was decided. The file is unchanged.")
        // Whatever the turn changed is checkpointed, cancelled or not — Stop doesn't undo writes
        // that already landed, and they stay reviewable and reversible (D1).
        checkpointTurn()
        defer { persistNewEntries() }
        switch stopReason {
        case "cancelled":
            setPhase(.idle)
            return
        case "refusal": append(.meta("\(agent.displayName) declined to continue."))
        case "max_tokens": append(.meta("\(agent.displayName) stopped at its output limit. Send another message to continue."))
        case "max_turn_requests": append(.meta("\(agent.displayName) reached its turn limit. Send another message to continue."))
        default: break
        }
        hasUnseenCompletion = true
        setPhase(.finishedTurn)
    }

    private func fail(_ message: String) {
        disarmStallTimer()
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The agent stopped before this edit was decided. The file is unchanged.")
        checkpointTurn()
        append(.failure(message))
        persistNewEntries()
        setPhase(.blocked(.failed))
    }

    // MARK: Session

    /// Launches the agent, negotiates the protocol, and opens a session in the track's worktree
    /// — once; later messages reuse it.
    private func withSession(_ body: @escaping (String) -> Void) {
        if let sessionId, connection?.isRunning == true { body(sessionId); return }
        sessionWaiters.append(body)
        // Already being opened (by `prepareSession`, or an earlier send): join it.
        guard !starting else { return }
        starting = true
        stoppedBySide = false
        if let connection, connection.isRunning {
            openSession(on: connection)
            return
        }
        let launchProvider = self.launchProvider
        let agent = self.agent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Finding the agent asks the login shell, so it stays off the main thread.
            let launch = launchProvider()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let launch else {
                        self.sessionFailed("\(agent.displayName) isn't installed, or isn't on your shell's PATH. Install it with:\n\n\(agent.installHint)")
                        return
                    }
                    self.start(launch)
                }
            }
        }
    }

    /// Opens the session before the first message so the agent's settings show in the pill.
    public func prepareSession() {
        guard sessionId == nil || connection?.isRunning != true, !starting, !phase.isBusy else { return }
        withSession { _ in }
    }

    private func sessionReady(_ id: String) {
        starting = false
        let waiters = sessionWaiters
        sessionWaiters.removeAll()
        for waiter in waiters { waiter(id) }
    }

    /// The session couldn't be opened. With a message waiting it's that turn's failure; opened
    /// ahead of time (nothing sent) it's a note, not a failed run.
    private func sessionFailed(_ message: String) {
        starting = false
        sessionWaiters.removeAll()
        // Side stopped it (the conversation closed while the agent was starting): nothing to
        // report. Its pending requests fail with "The agent was stopped." as the process goes,
        // and whether that beat the reply was a matter of timing: under load a notice was left
        // in the record (ACPFileTerminalTests, 2026-10-01).
        guard !stoppedBySide else { return }
        if phase.isBusy { fail(message) } else { append(.meta(message)) }
    }

    /// Set by `teardown`, cleared when a session starts again.
    private var stoppedBySide = false

    private func start(_ launch: ACPLaunch) {
        signIn = launch.signIn
        launchSearchPath = launch.environment["PATH"]
        let root = rootProvider()
        let connection: ACPConnection
        do {
            connection = try ACPConnection(launch: launch, cwd: root)
        } catch {
            sessionFailed("Couldn't start \(agent.displayName): \(error.localizedDescription)")
            return
        }
        self.connection = connection
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] id, method, params in self?.handleRequest(id: id, method: method, params: params) }
        connection.onExit = { [weak self] message in
            guard let self else { return }
            self.sessionId = nil
            self.connection = nil
            if self.starting { self.sessionFailed(message) }
            else if self.phase.isBusy || self.phase == .awaitingApproval { self.fail(message) }
        }
        connection.request("initialize", params: [
            "protocolVersion": 1,
            // Side's files (contained, unsaved-buffer-aware, approval per D9) and — when the app
            // provides them — Side's terminals, as visible Run tabs.
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": terminalHostProvider() != nil],
            "clientInfo": ["name": "side", "title": "Side", "version": "1"],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.sessionFailed("\(self.agent.displayName) didn't start: \(error.localizedDescription)")
            case .success(let value):
                let version = ((value as? [String: Any])?["protocolVersion"] as? NSNumber)?.intValue ?? 1
                guard version == 1 else {
                    self.sessionFailed("\(self.agent.displayName) speaks ACP version \(version); Side speaks version 1.")
                    connection.terminate()
                    return
                }
                let methods = (value as? [String: Any])?["authMethods"] as? [[String: Any]] ?? []
                let capabilities = (value as? [String: Any])?["agentCapabilities"] as? [String: Any]
                self.agentCanLoadSession = (capabilities?["loadSession"] as? Bool) ?? false
                self.agentTakesHTTPTools = ((capabilities?["mcpCapabilities"] as? [String: Any])?["http"] as? Bool) ?? false
                self.signInIfAsked(methods: methods, on: connection) { [weak self] in self?.openSession(on: connection) }
            }
        }
    }

    /// Agents that list sign-in methods (Codex: ChatGPT or an API key; Gemini: Google or an API
    /// key) are told which one the user chose, before a session opens. An agent already signed in
    /// that way answers at once; otherwise it may open a browser (ChatGPT, Google) to finish.
    /// Claude Code lists none: it uses whatever `claude` is signed into, or the key it was given.
    private func signInIfAsked(methods: [[String: Any]], on connection: ACPConnection, then next: @escaping () -> Void) {
        guard let method = Self.signInMethod(methods, for: signIn), let methodId = method["id"] as? String else { return next() }
        let how = signIn == .apiKey ? "an API key" : "your \(agent.subscriptionName)"
        // A browser sign-in can take a while; say so only if it does.
        let slow = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.append(.meta("Signing in to \(self.agent.displayName) with \(how). If a browser window opened, finish signing in there."))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: slow)
        connection.request("authenticate", params: ["methodId": methodId]) { [weak self] result in
            slow.cancel()
            guard let self else { return }
            switch result {
            case .success: next()
            case .failure(let error):
                let fix = self.signIn == .apiKey
                    ? "Check the key in Settings › Agents."
                    : "Sign in with the agent's CLI in a terminal, or choose an API key in Settings › Agents."
                self.sessionFailed("Couldn't sign in to \(self.agent.displayName) with \(how): \(error.localizedDescription). \(fix)")
            }
        }
    }

    /// The agent's method for a sign-in choice: one that takes an API key (`_meta["api-key"]`),
    /// or its own account login (not a gateway, Vertex, or device-code variant).
    static func signInMethod(_ methods: [[String: Any]], for signIn: ACPAgent.SignIn) -> [String: Any]? {
        func takesKey(_ method: [String: Any]) -> Bool { (method["_meta"] as? [String: Any])?["api-key"] != nil }
        switch signIn {
        case .apiKey:
            return methods.first(where: takesKey)
        case .subscription:
            return methods.first { method in
                let id = (method["id"] as? String ?? "").lowercased()
                return !takesKey(method) && !id.contains("gateway") && !id.contains("vertex") && !id.contains("device")
            }
        }
    }

    /// `session/new` in the track's worktree, on a running agent — the first session, or a
    /// fresh one after "New Conversation", which reuses the process rather than starting another.
    /// The MCP servers handed to the agent with a session: Side's own tools, when the agent can
    /// take an HTTP server. One URL per conversation, valid until it ends.
    private func sideToolServers() -> [Any] {
        guard agentTakesHTTPTools, let toolServer else { return [] }
        if toolServerRegistration == nil {
            let coordinator = coordinatorProvider()
            let bridge = coordinator.map { CoordinationBridge(parentKey: trackKey, coordinator: $0) }
            let box = WeakHarness(self)
            toolServerRegistration = toolServer.register(.init(
                trackKey: trackKey, tracks: trackContext, coordination: bridge, agentChoices: coordinator?.agentChoices ?? [],
                authorize: { tool, title, fullMaySkip, decided in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let harness = box.value else { return decided(false) }
                            harness.authorizeCoordinatorAction(tool: tool, title: title, fullMaySkip: fullMaySkip, decided: decided)
                        }
                    }
                }
            ))
        }
        guard let url = toolServerRegistration?.url else { return [] }
        return [["type": "http", "name": "side", "url": url.absoluteString, "headers": [Any]()]]
    }

    /// M1 and M2 for an outside coordinator: Full skips the card when the rule allows it; a
    /// call the user just allowed on the agent's own card needs no second card (D9); otherwise a
    /// Side card asks.
    private func authorizeCoordinatorAction(tool: String, title: String, fullMaySkip: Bool, decided: @escaping @Sendable (Bool) -> Void) {
        if fullMaySkip, modeProvider().autonomy.autoAppliesEdits { return decided(true) }
        if let granted = coordinatorGrants[tool], Date().timeIntervalSince(granted) < 120 {
            coordinatorGrants.removeValue(forKey: tool)
            return decided(true)
        }
        streamingIndex = nil
        thinkingIndex = nil
        let verb = tool == "promote_subtrack" ? "Promote" : "Create"
        let presentation = PermissionPresentation(
            title: title,
            options: [.init(id: "side-allow", name: verb, kind: .allowOnce), .init(id: "side-reject", name: "Don't \(verb.lowercased())", kind: .rejectOnce)]
        )
        let index = append(.permissionRequest(presentation))
        pendingSpawnApprovals[entries[index].id] = decided
        setPhase(.awaitingApproval)
    }

    private func openSession(on connection: ACPConnection) {
        let root = rootProvider()
        // Side's own tools, then the user's servers switched on for this project (Library).
        let mcpServers = sideToolServers() + (usageProjectPath.map { MCPServerStore.acpDescriptors(forProject: $0, searchPath: launchSearchPath) as [Any] } ?? [])
        // Reopen the agent's own session when this conversation had one and the agent can:
        // then it remembers what was said. Its replay of that history isn't drawn again; Side's
        // record already shows it.
        if let stored = storedAgentSessionId, agentCanLoadSession {
            replaying = true
            connection.request("session/load", params: ["sessionId": stored, "cwd": root.path, "mcpServers": mcpServers]) { [weak self] result in
                guard let self else { return }
                self.replaying = false
                switch result {
                case .success(let value):
                    self.sessionId = stored
                    let (options, backing) = Self.options(from: value)
                    if !options.isEmpty { (self.agentOptions, self.optionBacking) = (options, backing) }
                    self.applyPreferredOptions()
                    self.rememberKnownOptions()
                    self.notify(.phaseChanged)
                    self.sessionReady(stored)
                case .failure:
                    // The agent stopped (Side closed it, or it crashed): nothing to fall back
                    // on. A crash is reported once, with its own output, by `onExit`.
                    guard !self.ended(connection) else { return }
                    self.storedAgentSessionId = nil
                    self.append(.meta("\(self.agent.displayName) couldn't reopen its earlier session, so it starts a new one. The conversation above stays here, but the agent won't remember it."))
                    self.openSession(on: connection)
                }
            }
            return
        }
        connection.request("session/new", params: ["cwd": root.path, "mcpServers": mcpServers]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                guard !self.ended(connection) else { return }
                self.sessionFailed(Self.explain(error, agent: self.agent))
            case .success(let value):
                guard let id = (value as? [String: Any])?["sessionId"] as? String else {
                    self.sessionFailed("\(self.agent.displayName) didn't open a session.")
                    return
                }
                self.sessionId = id
                self.recordAgentSession(id)
                (self.agentOptions, self.optionBacking) = Self.options(from: value)
                self.applyPreferredOptions()
                self.rememberKnownOptions()
                self.notify(.phaseChanged)
                self.sessionReady(id)
            }
        }
    }

    /// The connection a reply belongs to is gone: stopped by `teardown` (a window closing, an
    /// agent restarting) or exited on its own. Its pending requests fail as it goes, and those
    /// failures aren't the agent's answer, so they mustn't read as one. They used to: a reopen cut
    /// short left "couldn't reopen its earlier session" and "The agent isn't running" in the
    /// record, again on every launch.
    private func ended(_ connection: ACPConnection) -> Bool {
        self.connection !== connection || !connection.isRunning
    }

    /// Agents that need a login say so when a session is requested; point at the CLI's own login.
    private static func explain(_ error: Error, agent: ACPAgent) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
            return "\(agent.displayName) needs you to sign in. Run its CLI once in a terminal to log in, then try again.\n\n(\(text))"
        }
        return "\(agent.displayName) couldn't open a session: \(text)"
    }

    // MARK: Updates from the agent

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        armStallTimerIfRunning()
        if method == "_auth/status_update", let status = params["authStatus"] as? [String: Any] {
            // "Claude Team", or "Anthropic API key" — which one pays matters to the user.
            accountLabel = status["label"] as? String
            notify(.phaseChanged)
            return
        }
        guard method == "session/update", let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        if replaying, !["config_option_update", "current_mode_update", "usage_update"].contains(kind) { return }
        switch kind {
        case "agent_message_chunk":
            guard let text = Self.text(update["content"]) else { return }
            thinkingIndex = nil
            if let index = streamingIndex, case .assistantText(var existing) = entries[index].kind {
                // Let go of the entry's copy first, so the append doesn't copy the whole message
                // per chunk (SIDE_RFC_HERON_EFFICIENCY.md, D6).
                entries[index].kind = .assistantText("")
                existing += text
                replace(index, .assistantText(existing))
            } else {
                streamingIndex = append(.assistantText(text))
            }
        case "agent_thought_chunk":
            guard let text = Self.text(update["content"]) else { return }
            if let index = thinkingIndex, case .thinking(var existing) = entries[index].kind {
                entries[index].kind = .thinking("")
                existing += text
                replace(index, .thinking(existing))
            } else {
                thinkingIndex = append(.thinking(text))
            }
        case "tool_call":
            streamingIndex = nil
            thinkingIndex = nil
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let title = update["title"] as? String ?? "Working"
            noteToolCall(id: id, update)
            if update["status"] as? String == "completed" { markTouched(byToolCall: id) }
            toolEntryIndex[id] = append(.toolCall(name: title, summary: Self.locationSummary(update["locations"], besides: title)))
            if phase == .streaming { setPhase(.runningTools) }
        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? ""
            noteToolCall(id: id, update)
            if update["status"] as? String == "completed" { markTouched(byToolCall: id) }
            guard let index = toolEntryIndex[id], case .toolCall(let name, let summary) = entries[index].kind else { return }
            let title = update["title"] as? String ?? name
            let locations = update["locations"] != nil ? Self.locationSummary(update["locations"], besides: title) : summary
            // The result folds into its own tool line — a permission card can sit between the
            // call and its completion, and a separate result line then landed in a new, empty
            // "Worked for…" group of its own.
            switch update["status"] as? String {
            case "completed":
                replace(index, .toolCall(name: title, summary: locations + " · ✓ " + Self.resultSummary(update["content"])))
                if phase == .runningTools { setPhase(.streaming) }
            case "failed":
                replace(index, .toolCall(name: title, summary: locations + " · ⚠︎ " + Self.resultSummary(update["content"])))
                if phase == .runningTools { setPhase(.streaming) }
            default:
                if title != name || locations != summary { replace(index, .toolCall(name: title, summary: locations)) }
            }
        case "config_option_update":
            let (options, backing) = Self.options(from: ["configOptions": update["configOptions"] ?? []])
            guard !options.isEmpty else { return }
            agentOptions = options
            optionBacking = backing
            rememberKnownOptions()
            notify(.phaseChanged)
        case "current_mode_update":
            guard let mode = update["currentModeId"] as? String,
                  let index = agentOptions.firstIndex(where: { optionBacking[$0.id] == .mode }) else { return }
            agentOptions[index].current = mode
            notify(.phaseChanged)
        case "usage_update":
            if let used = (update["used"] as? NSNumber)?.intValue, let size = (update["size"] as? NSNumber)?.intValue, size > 0 {
                usage = (used, size)
                notify(.phaseChanged) // the pill's context %
            }
        default:
            break // plans, command lists, mode changes: not shown yet
        }
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) {
        armStallTimerIfRunning()
        switch method {
        case "session/request_permission": requestPermission(id: id, params: params)
        case "fs/read_text_file": readTextFile(id: id, params: params)
        case "fs/write_text_file": writeTextFile(id: id, params: params)
        case "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
            handleTerminal(id: id, method: method, params: params)
        default:
            connection?.respondError(id: id, code: -32601, message: "Side doesn't offer \(method).")
        }
    }

    private func requestPermission(id: Any, params: [String: Any]) {
        let toolCall = params["toolCall"] as? [String: Any]
        let toolCallId = toolCall?["toolCallId"] as? String
        if let toolCall, let toolCallId { noteToolCall(id: toolCallId, toolCall) }
        let paths = toolCallId.flatMap { toolCalls[$0]?.paths } ?? []
        let title = (toolCall?["title"] as? String) ?? toolCall.flatMap { ($0["toolCallId"] as? String).flatMap { toolEntryIndex[$0] } }.flatMap { index -> String? in
            if case .toolCall(let name, _) = entries[index].kind { return name }
            return nil
        } ?? "\(agent.displayName) wants to continue"
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> PermissionPresentation.Option? in
            guard let optionId = option["optionId"] as? String else { return nil }
            return PermissionPresentation.Option(id: optionId, name: option["name"] as? String ?? optionId,
                                                 kind: (option["kind"] as? String).flatMap(PermissionPresentation.Option.Kind.init(rawValue:)))
        }
        let index = append(.permissionRequest(PermissionPresentation(title: title, options: options)))
        pendingPermissions[entries[index].id] = PendingPermission(requestId: id, paths: paths)
        setPhase(.awaitingApproval)
    }

    public func answerPermission(proposalId: UUID, optionId: String?) {
        if let decided = pendingSpawnApprovals.removeValue(forKey: proposalId) {
            if let index = entries.firstIndex(where: { $0.id == proposalId }), case .permissionRequest(var presentation) = entries[index].kind {
                let promote = presentation.title.hasPrefix("Promote")
                presentation.chosenOptionName = optionId == "side-allow" ? (promote ? "Promoted" : "Created") : (promote ? "Not promoted" : "Not created")
                replace(index, .permissionRequest(presentation))
            }
            decided(optionId == "side-allow")
            resumeIfNothingPending()
            return
        }
        guard let pending = pendingPermissions.removeValue(forKey: proposalId),
              let index = entries.firstIndex(where: { $0.id == proposalId }),
              case .permissionRequest(var presentation) = entries[index].kind else { return }
        let requestId = pending.requestId
        if let optionId {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "selected", "optionId": optionId]])
            let chosen = presentation.options.first { $0.id == optionId }
            presentation.chosenOptionName = chosen?.name ?? optionId
            // Allowed: the diff was on this card, so a write it leads to needs no second one.
            if chosen?.kind == .allowOnce || chosen?.kind == .allowAlways {
                grantedPaths.formUnion(pending.paths)
                for tool in ["create_subtrack", "promote_subtrack"] where presentation.title.contains(tool) { coordinatorGrants[tool] = Date() }
            }
        } else {
            connection?.respond(id: requestId, result: ["outcome": ["outcome": "cancelled"]])
            presentation.chosenOptionName = "Cancelled"
        }
        replace(index, .permissionRequest(presentation))
        resumeIfNothingPending()
    }

    private func resumeIfNothingPending() {
        if pendingPermissions.isEmpty, pendingWrites.isEmpty, pendingSpawnApprovals.isEmpty, phase == .awaitingApproval { setPhase(.streaming) }
    }

    private func declinePendingSpawns() {
        for (id, decided) in pendingSpawnApprovals {
            if let index = entries.firstIndex(where: { $0.id == id }), case .permissionRequest(var presentation) = entries[index].kind {
                presentation.chosenOptionName = "Cancelled"
                replace(index, .permissionRequest(presentation))
            }
            decided(false)
        }
        pendingSpawnApprovals.removeAll()
    }

    private func answerPendingPermissions(with optionId: String?) {
        for id in Array(pendingPermissions.keys) { answerPermission(proposalId: id, optionId: optionId) }
        declinePendingSpawns()
    }

    // MARK: Other actions

    public func stop() {
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "Stopped before this edit was decided. The file is unchanged.")
        // The commands stop too; their tabs stay so the output can still be read.
        terminalHostProvider()?.endAll(owner: ownerId, closeTabs: false)
        if let sessionId { connection?.notify("session/cancel", params: ["sessionId": sessionId]) }
        // The prompt's own response arrives with stopReason "cancelled" and settles the phase;
        // if the agent is gone, settle it here.
        if connection?.isRunning != true { setPhase(.idle) }
    }

    /// Apply or Reject on the card an unannounced write produced (D9, Manual and Guarded).
    public func resolve(proposalId: UUID, decision: ProposalDecision) {
        guard let pending = pendingWrites.removeValue(forKey: proposalId) else { return }
        switch decision {
        case .apply:
            let outcome = apply(pending.edit, requestId: pending.requestId)
            setResolution(proposalId, ProposalPresentation.Resolution(outcome))
        case .reject:
            connection?.respondError(id: pending.requestId, code: -32000, message: ProposedEditOutcome.rejected.toolResultText)
            setResolution(proposalId, .rejected)
        }
        resumeIfNothingPending()
    }

    public func acknowledgeCompletion() {
        guard hasUnseenCompletion else { return }
        hasUnseenCompletion = false
        notify(.phaseChanged)
    }

    public func editableMessage(turnId: UUID) -> (text: String, attachments: [AgentImageAttachment])? { nil }
    public func editAndResend(turnId: UUID, text: String, attachments: [AgentImageAttachment]) { send(text, attachments: attachments) }

    public var canUndoCompaction: Bool { false }
    public func undoCompaction() -> Bool { false }

    public func compact(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(ACPConnection.RemoteError(code: -32601, message: "\(agent.displayName) manages its own context.")))
    }

    /// A fresh conversation is a fresh session: the next message opens a new one.
    public func startNewConversation() {
        guard !phase.isBusy else { return }
        sessionStore?.archiveOutsideLog(trackKey: trackKey, agentId: agent.id)
        persistedCount = 0
        headerWritten = false
        storedAgentSessionId = nil
        sessionId = nil
        entries.removeAll()
        toolEntryIndex.removeAll()
        toolCalls.removeAll()
        bases.removeAll()
        appliedCounts.removeAll()
        conversationId = UUID()
        usage = nil
        agentOptions = seededOptions()
        notify(.reset)
        setPhase(.idle)
        prepareSession()
    }

    /// Reopens a past conversation: its record becomes current (the current one is filed away),
    /// and the agent's own session for it is reopened on the next open, so it remembers.
    public func openArchivedConversation(id: UUID) -> Bool {
        guard !phase.isBusy, phase != .awaitingApproval else { return false }
        persistNewEntries() // the current conversation is filed complete
        guard sessionStore?.openOutsideArchive(id: id, trackKey: trackKey, agentId: agent.id) == true else { return false }
        entries.removeAll()
        toolEntryIndex.removeAll()
        toolCalls.removeAll()
        bases.removeAll()
        appliedCounts.removeAll()
        usage = nil
        sessionId = nil
        storedAgentSessionId = nil
        persistedCount = 0
        headerWritten = false
        conversationId = UUID()
        restoreFromLog()
        notify(.reset)
        setPhase(.idle)
        prepareSession()
        return true
    }

    public func contextUsage() -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: ContextBudget.Status) {
        guard let usage else { return (0, 0, 0, .comfortable) }
        let fraction = Double(usage.used) / Double(usage.size)
        let status: ContextBudget.Status = fraction >= 0.9 ? .critical : (fraction >= 0.7 ? .approaching : .comfortable)
        return (usage.used, usage.size, fraction, status)
    }

    /// Run's task chips stay with Heron for now (RFC D8 is plan step 4).
    public func proposeUserTask(_ task: ProjectTask) -> UUID? { nil }

    public func teardown() {
        stoppedBySide = true
        disarmStallTimer()
        if let token = toolServerRegistration?.token { toolServer?.unregister(token: token) }
        toolServerRegistration = nil
        sessionWaiters.removeAll()
        defer { persistNewEntries() }
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The conversation closed before this edit was decided. The file is unchanged.")
        terminalHostProvider()?.endAll(owner: ownerId, closeTabs: true)
        connection?.terminate()
        connection = nil
        sessionId = nil
    }


    // MARK: Files (plan step 3a/3b)

    /// Worktree-relative, the shape `GitPaths.dirtyPaths` uses. Both sides symlink-resolved
    /// (`/var` is `/private/var`).
    nonisolated static func relative(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// A path the agent named, resolved and contained to the track's worktree — or nil.
    private func contained(_ path: String) -> URL? {
        ProjectFileAccess.resolveInsideProject(path: path, root: rootProvider())
    }

    /// What the file holds right now: the open buffer (unsaved edits included), else disk. Nil
    /// when the file doesn't exist; `.binary` when it isn't text.
    private enum Current { case missing, binary, text(String) }
    private func currentContent(_ url: URL) -> Current {
        if let live = bridgeProvider().liveBufferProvider(url) { return .text(live) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if TextFileCodec.looksBinary(data) { return .binary }
        return TextFileCodec.decode(data).map { .text($0.text) } ?? .binary
    }

    private func readTextFile(id: Any, params: [String: Any]) {
        guard let path = params["path"] as? String, let url = contained(path) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: that path is outside this track's working copy.")
            return
        }
        guard ProjectFileAccess.isReadable(url, root: rootProvider()) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: Side's own state isn't readable.")
            return
        }
        switch currentContent(url) {
        case .missing:
            connection?.respondError(id: id, code: -32002, message: "No such file: \(path)")
        case .binary:
            connection?.respondError(id: id, code: -32000, message: "\(url.lastPathComponent) isn't a text file.")
        case .text(let text):
            bases[url.path] = text
            connection?.respond(id: id, result: ["content": Self.slice(text, line: (params["line"] as? NSNumber)?.intValue, limit: (params["limit"] as? NSNumber)?.intValue)])
        }
    }

    /// `line` is 1-based; `limit` is a line count.
    static func slice(_ text: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return "" }
        let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    private func writeTextFile(id: Any, params: [String: Any]) {
        guard let path = params["path"] as? String, let content = params["content"] as? String, let url = contained(path) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: that path is outside this track's working copy.")
            return
        }
        let root = rootProvider()
        guard ProjectFileAccess.isWritable(url, root: root) else {
            connection?.respondError(id: id, code: -32602, message: "Refused: \(url.lastPathComponent) is in a location Side doesn't let agents write (.git, .side).")
            return
        }
        // The base: what the agent was shown. A write computed against anything else would
        // overwrite whatever happened since — unsaved typing included.
        let base: String?
        switch currentContent(url) {
        case .binary:
            connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) isn't a text file.")
            return
        case .missing:
            base = nil
        case .text(let now):
            guard let seen = bases[url.path] else {
                connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) already exists and hasn't been read. Read it with fs/read_text_file first, then write.")
                return
            }
            guard seen == now else {
                connection?.respondError(id: id, code: -32000, message: "Refused: \(url.lastPathComponent) changed since you read it. Read it again, then write.")
                return
            }
            base = now
        }
        let relative = Self.relative(url, root: root)
        let edit = ProposedEdit(toolUseId: "acp", url: url, relativePath: relative,
                                baseContent: base ?? "", proposedContent: content, isNewFile: base == nil)
        // D9: allowed on the agent's own card, or Full autonomy → no second card.
        if grantedPaths.contains(url.path) || modeProvider().autonomy.autoAppliesEdits {
            _ = apply(edit, requestId: id)
            return
        }
        // Unannounced, and the track asks first: a card, like Heron's. The diff is computed off
        // the main thread (a `git diff` spawn), then the card appears.
        let original = base ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = GitDiffComputer.unifiedDiffText(original: original, proposed: content, projectRoot: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.streamingIndex = nil
                    self.thinkingIndex = nil
                    let index = self.append(.proposal(ProposalPresentation(edit: edit, diffText: diff, resolution: nil)))
                    self.pendingWrites[self.entries[index].id] = (id, edit)
                    self.setPhase(.awaitingApproval)
                }
            }
        }
    }

    /// The one way an outside agent's write reaches disk: disk first, then the open buffer,
    /// refusing if the base moved in the meantime.
    @discardableResult
    private func apply(_ edit: ProposedEdit, requestId: Any) -> ProposedEditOutcome {
        let bridge = bridgeProvider()
        let applier = ProposedEditApplier(applyIntoOpenTab: bridge.applyEditIntoOpenTab) { [weak self] url in
            guard let self, case .text(let text) = self.currentContent(url) else { return nil }
            return text
        }
        let outcome = applier.apply(edit)
        if case .applied = outcome {
            bases[edit.url.path] = edit.proposedContent
            turnTouched.insert(edit.relativePath)
            connection?.respond(id: requestId, result: [:])
        } else {
            connection?.respondError(id: requestId, code: -32000, message: outcome.toolResultText)
        }
        return outcome
    }

    private func setResolution(_ entryId: UUID, _ resolution: ProposalPresentation.Resolution) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }), case .proposal(var presentation) = entries[index].kind else { return }
        presentation.resolution = resolution
        presentation.edit.stripContent()
        replace(index, .proposal(presentation))
    }

    private func settlePendingWrites(reason: String) {
        for (entryId, pending) in pendingWrites {
            connection?.respondError(id: pending.requestId, code: -32000, message: reason)
            setResolution(entryId, .rejected)
        }
        pendingWrites.removeAll()
    }

    /// Paths and diff bases from a tool call or its update.
    private func noteToolCall(id: String, _ update: [String: Any]) {
        var entry = toolCalls[id] ?? (kind: nil, paths: [])
        if let kind = update["kind"] as? String { entry.kind = kind }
        for location in update["locations"] as? [[String: Any]] ?? [] {
            if let path = location["path"] as? String, let url = contained(path) { entry.paths.insert(url.path) }
        }
        for item in update["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "diff" {
            guard let path = item["path"] as? String, let url = contained(path) else { continue }
            entry.paths.insert(url.path)
            // The agent's own view of the file before its change — a base for a write that
            // follows, when it read the file with its own tools rather than Side's.
            if let old = item["oldText"] as? String, bases[url.path] == nil { bases[url.path] = old }
        }
        toolCalls[id] = entry
    }

    /// A completed tool call that changes files: its paths are the agent's in this turn's
    /// checkpoint. Reads and searches don't count — a file the user already had dirty mustn't be
    /// committed just because the agent looked at it.
    private func markTouched(byToolCall id: String) {
        guard let call = toolCalls[id], ["edit", "delete", "move"].contains(call.kind ?? "") || call.kind == nil && !call.paths.isEmpty else { return }
        let root = rootProvider()
        for path in call.paths { turnTouched.insert(Self.relative(URL(fileURLWithPath: path), root: root)) }
    }

    // MARK: Terminals (plan step 3a/3c)

    private func handleTerminal(id: Any, method: String, params: [String: Any]) {
        guard let host = terminalHostProvider() else {
            connection?.respondError(id: id, code: -32601, message: "Side doesn't offer terminals here.")
            return
        }
        let terminalId = params["terminalId"] as? String ?? ""
        switch method {
        case "terminal/create":
            guard let command = params["command"] as? String, !command.isEmpty else {
                connection?.respondError(id: id, code: -32602, message: "terminal/create needs a command.")
                return
            }
            let root = rootProvider()
            let cwd: URL
            if let requested = params["cwd"] as? String {
                guard let inside = contained(requested) else {
                    connection?.respondError(id: id, code: -32602, message: "Refused: \(requested) is outside this track's working copy.")
                    return
                }
                cwd = inside
            } else {
                cwd = root
            }
            let arguments = params["args"] as? [String] ?? []
            var environment: [String: String] = [:]
            for variable in params["env"] as? [[String: Any]] ?? [] {
                if let name = variable["name"] as? String, let value = variable["value"] as? String { environment[name] = value }
            }
            let limit = (params["outputByteLimit"] as? NSNumber)?.intValue ?? 1_000_000
            do {
                let terminalId = try host.createTerminal(trackKey: trackKey, command: command, arguments: arguments, environment: environment,
                                                         cwd: cwd, outputByteLimit: limit, owner: ownerId)
                turnCommands.append(([command] + arguments).joined(separator: " "))
                connection?.respond(id: id, result: ["terminalId": terminalId])
            } catch {
                connection?.respondError(id: id, code: -32000, message: "Couldn't start \(command): \(error.localizedDescription)")
            }
        case "terminal/output":
            guard let output = host.output(of: terminalId) else { return unknownTerminal(id) }
            var result: [String: Any] = ["output": output.output, "truncated": output.truncated]
            if let exit = output.exit { result["exitStatus"] = exit.json }
            connection?.respond(id: id, result: result)
        case "terminal/wait_for_exit":
            waitingOnTerminals += 1
            disarmStallTimer()
            let known = host.waitForExit(terminalId) { [weak self] exit in
                guard let self else { return }
                self.waitingOnTerminals = max(0, self.waitingOnTerminals - 1)
                self.connection?.respond(id: id, result: exit.json)
                self.armStallTimerIfRunning()
            }
            if !known {
                waitingOnTerminals = max(0, waitingOnTerminals - 1)
                unknownTerminal(id)
            }
        case "terminal/kill":
            host.kill(terminalId) ? connection?.respond(id: id, result: [:]) : unknownTerminal(id)
        default: // terminal/release
            host.release(terminalId) ? connection?.respond(id: id, result: [:]) : unknownTerminal(id)
        }
    }

    private func unknownTerminal(_ id: Any) {
        connection?.respondError(id: id, code: -32602, message: "No such terminal.")
    }

    // MARK: Stalls

    private func armStallTimerIfRunning() {
        if phase == .streaming || phase == .runningTools { armStallTimer() }
    }

    /// A turn that goes silent for `stallInterval` says so, instead of looking busy forever —
    /// the same promise Heron's watchdog keeps (constitution: attention is explicit).
    private func armStallTimer() {
        guard waitingOnTerminals == 0 else { stallWatchdog.stop(); return }
        stallWatchdog.feed()
    }

    /// The turn went silent for `stallInterval`.
    private func stallFired() {
        guard phase == .streaming || phase == .runningTools, waitingOnTerminals == 0 else { return }
        if let sessionId { connection?.notify("session/cancel", params: ["sessionId": sessionId]) }
        streamingIndex = nil
        thinkingIndex = nil
        answerPendingPermissions(with: nil)
        settlePendingWrites(reason: "The turn stalled before this edit was decided. The file is unchanged.")
        checkpointTurn()
        let seconds = Int(stallInterval)
        let span = seconds >= 120 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
        append(.failure("No response from \(agent.displayName) for \(span), so Side stopped waiting. Send the message again. If it keeps happening, run the agent's CLI in a terminal to check it works and is signed in."))
        persistNewEntries()
        setPhase(.blocked(.stalled))
    }

    private func disarmStallTimer() { stallWatchdog.stop() }

    // MARK: The agent's own settings (plan step 4, D6)

    /// Options from a session result or a `config_option_update`: `configOptions` when the agent
    /// has them, else its older `modes` and `models`.
    static func options(from sessionResult: Any) -> ([HarnessOption], [String: OptionBacking]) {
        let result = sessionResult as? [String: Any] ?? [:]
        var options: [HarnessOption] = []
        var backing: [String: OptionBacking] = [:]
        func choice(_ raw: [String: Any], valueKey: String) -> HarnessOption.Choice? {
            guard let value = raw[valueKey] as? String else { return nil }
            return HarnessOption.Choice(value: value, name: raw["name"] as? String ?? value, detail: raw["description"] as? String,
                                        kind: (raw["_meta"] as? [String: Any])?["kind"] as? String)
        }
        for raw in result["configOptions"] as? [[String: Any]] ?? [] {
            guard let id = raw["id"] as? String, let current = raw["currentValue"] as? String,
                  (raw["type"] as? String ?? "select") == "select" else { continue }
            let category: HarnessOption.Category
            switch raw["category"] as? String {
            case "model": category = .model
            case "thought_level": category = .effort
            case "mode": category = .mode
            default: category = .other
            }
            let choices = (raw["options"] as? [[String: Any]] ?? []).compactMap { choice($0, valueKey: "value") }
            options.append(HarnessOption(id: id, name: raw["name"] as? String ?? id, category: category, current: current, choices: choices))
            backing[id] = .config
        }
        guard options.isEmpty else { return (options, backing) }
        if let modes = result["modes"] as? [String: Any], let current = modes["currentModeId"] as? String {
            let choices = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap { choice($0, valueKey: "id") }
            options.append(HarnessOption(id: "mode", name: "Mode", category: .mode, current: current, choices: choices))
            backing["mode"] = .mode
        }
        if let models = result["models"] as? [String: Any], let current = models["currentModelId"] as? String {
            let choices = (models["availableModels"] as? [[String: Any]] ?? []).compactMap { choice($0, valueKey: "modelId") }
            options.insert(HarnessOption(id: "model", name: "Model", category: .model, current: current, choices: choices), at: 0)
            backing["model"] = .model
        }
        return (options, backing)
    }

    /// (id, current choice's name) — the session line's parts.
    static func settings(from sessionResult: Any) -> [(id: String, value: String)] {
        options(from: sessionResult).0.map { ($0.id, $0.currentChoice?.name ?? $0.current) }
    }

    /// Changes one of the agent's settings. Remembered on the track either way; sent now if a
    /// session is open, else applied when one opens.
    public func setAgentOption(id: String, value: String) {
        setAgentOption(id: id, value: value, remember: true)
    }

    private func setAgentOption(id: String, value: String, remember: Bool) {
        if remember { onOptionChanged(id, value) }
        guard let index = agentOptions.firstIndex(where: { $0.id == id }),
              agentOptions[index].choices.contains(where: { $0.value == value }),
              agentOptions[index].current != value else { return }
        guard let sessionId, let connection else {
            // No session yet: shown now, sent when one opens (`applyPreferredOptions`).
            agentOptions[index].current = value
            notify(.phaseChanged)
            return
        }
        let previous = agentOptions[index].current
        agentOptions[index].current = value
        notify(.phaseChanged)
        let name = agentOptions[index].name
        let (method, params): (String, [String: Any])
        switch optionBacking[id] ?? .config {
        case .config: (method, params) = ("session/set_config_option", ["sessionId": sessionId, "configId": id, "value": value])
        case .mode: (method, params) = ("session/set_mode", ["sessionId": sessionId, "modeId": value])
        case .model: (method, params) = ("session/set_model", ["sessionId": sessionId, "modelId": value])
        }
        connection.request(method, params: params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                // Setting one option can change others (a model has its own effort levels).
                let (options, backing) = Self.options(from: value)
                if !options.isEmpty {
                    self.agentOptions = options
                    self.optionBacking = backing
                    self.notify(.phaseChanged)
                }
            case .failure(let error):
                if let index = self.agentOptions.firstIndex(where: { $0.id == id }) { self.agentOptions[index].current = previous }
                self.append(.meta("Couldn't change \(self.agent.displayName)'s \(name.lowercased()): \(error.localizedDescription)"))
                self.notify(.phaseChanged)
            }
        }
    }

    /// The track's remembered choices, applied to a freshly opened session. Sent before the
    /// first prompt on the same stream, so the prompt runs with them.
    private func applyPreferredOptions() {
        for (id, value) in preferredOptions() { setAgentOption(id: id, value: value, remember: false) }
    }

    // MARK: The turn's checkpoint

    /// Commits what the turn changed, however it was written (D1): paths the agent is known to
    /// have changed, plus paths that became dirty during the turn — minus paths the user saved
    /// in Make meanwhile, which are theirs. Runs once per turn.
    private func checkpointTurn() {
        guard let known = turnBaseline, let sessionStore else { turnBaseline = nil; return }
        let baseline: Set<String>? = turnBaselineUnknown ? nil : known
        turnBaseline = nil
        let root = rootProvider().path
        let touched = turnTouched
        let userSaved = UserSaveLog.shared.paths(savedSince: turnStartedAt, under: root)
        let shared = touched.intersection(userSaved)
        let firstLine = turnPrompt.split(separator: "\n").first.map(String.init) ?? ""
        let intent = firstLine.count > 72 ? String(firstLine.prefix(71)) + "…" : firstLine
        let commands = turnCommands
        let (trackKey, conversationId, agent) = (self.trackKey, self.conversationId, self.agent)
        let logURL = self.logURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only touched paths that actually differ now: a path the agent changed and changed
            // back has nothing to commit, and `git add` of a vanished untracked path would fail.
            // A failed status here fails the commit's own status too, which is reported.
            let dirty = GitPaths.dirtyPaths(cwd: root) ?? []
            let outcome = AgentRunner.stageAndCommit(root: root, baseline: baseline, knownChanged: touched.intersection(dirty),
                                                     userSaved: userSaved, message: intent.isEmpty ? "\(agent.displayName) checkpoint" : intent)
            var fileChanges: [CheckpointFileChange] = []
            if let sha = outcome?.commit?.sha {
                fileChanges = Self.numstat(sha: sha, cwd: root)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The ledger entry is written even if this conversation has been put away in
                    // the meantime (the app quitting right after a turn): a commit with no
                    // checkpoint record can't be found in Review or undone from it.
                    var lines: [RunTranscriptEntry.Kind] = []
                    switch outcome {
                    case .none, .nothingToCommit?:
                        return
                    case .failed(let step, let message)?:
                        lines.append(.failure("Couldn't create a checkpoint: git \(step) failed\(message.isEmpty ? "" : ": \(message)").\nThe changes are still in your working copy, uncommitted."))
                    case .committed(let sha, let paths)?, .committedIndexStale(let sha, let paths)?:
                        if let warning = outcome?.staleIndexWarning { lines.append(.failure(warning)) }
                        let names = paths.map { ($0 as NSString).lastPathComponent }
                        let described = intent.isEmpty
                            ? (names.count == 1 ? "Edited \(names[0])" : "Edited \(names.first ?? "files") and \(max(0, names.count - 1)) other files")
                            : intent
                        let checkpoint = Checkpoint(
                            trackKey: trackKey, agentSessionId: conversationId, declaredIntent: described,
                            changedFilePaths: paths, commandsRun: commands,
                            provenance: AgentProvenance(providerId: "acp:\(agent.id)", modelId: agent.displayName, instructionSourceSummary: "\(agent.displayName) conversation"),
                            gitCommitSHA: sha, fileChanges: fileChanges)
                        sessionStore.appendCheckpoint(checkpoint)
                        lines.append(.checkpoint(id: checkpoint.id, text: AgentRunner.checkpointMarker(checkpoint)))
                        let sharedNames = shared.sorted().map { ($0 as NSString).lastPathComponent }
                        if !sharedNames.isEmpty {
                            lines.append(.meta("Also has your own saved edits, committed with the agent's: \(sharedNames.joined(separator: ", "))."))
                        }
                        if let self {
                            for change in fileChanges {
                                let existing = self.appliedCounts[change.path] ?? (0, 0)
                                self.appliedCounts[change.path] = (existing.added + change.added, existing.removed + change.removed)
                            }
                        }
                    }
                    if let self {
                        for line in lines { self.append(line) }
                        self.persistNewEntries()
                    } else if let logURL {
                        OutsideSessionLog.append(lines.compactMap { OutsideSessionLog.record(for: RunTranscriptEntry(kind: $0)) }, to: logURL)
                    }
                }
            }
        }
    }

    /// Per-file line counts of one commit.
    private nonisolated static func numstat(sha: String, cwd: String) -> [CheckpointFileChange] {
        let result = GitPaths.runGitRaw(["show", "--numstat", "--format=", sha], cwd: cwd)
        guard result.success else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return CheckpointFileChange(path: parts[2], added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
    }

    // MARK: Content helpers

    /// A content block's text (`{"type":"text","text":…}`), or nil for images and the like.
    private static func text(_ content: Any?) -> String? {
        guard let block = content as? [String: Any], block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }

    /// " path/one, path/two" from a tool call's `locations`, for the tool line's summary — minus
    /// any the title already names ("Read README.md" needs no second "README.md").
    private static func locationSummary(_ locations: Any?, besides title: String) -> String {
        let paths = (locations as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            .filter { !title.contains(($0 as NSString).lastPathComponent) }
        guard !paths.isEmpty else { return "" }
        let names = paths.prefix(2).map { ($0 as NSString).lastPathComponent }
        return " " + names.joined(separator: ", ") + (paths.count > 2 ? " +\(paths.count - 2)" : "")
    }

    /// One short line about what a finished tool produced: the files it changed, or its text.
    private static func resultSummary(_ content: Any?) -> String {
        let items = content as? [[String: Any]] ?? []
        let changed = items.filter { $0["type"] as? String == "diff" }.compactMap { $0["path"] as? String }
        if !changed.isEmpty {
            return "Changed " + changed.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
        for item in items where item["type"] as? String == "content" {
            if let text = text(item["content"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let line = text.split(separator: "\n").first.map(String.init) ?? text
                return line.count > 120 ? String(line.prefix(120)) + "…" : line
            }
        }
        return "Done"
    }
}
