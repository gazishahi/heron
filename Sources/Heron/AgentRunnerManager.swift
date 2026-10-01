import Foundation

/// Owns at most one `AgentRunner` per track key for a single project, spawned lazily on first
/// visit — the `AgentRunner` analog of `LSPManager` (lazy per-key creation, explicit discard,
/// teardown-all on project close). Lives on `ProjectContext`, so it's shared across every window
/// that has the project open, the same as `TrackStore`/`AgentSessionStore`.
@MainActor
public final class AgentRunnerManager {
    private let sessionStore: AgentSessionStore
    /// The project these runners belong to, used to file their token usage — the *project* root,
    /// not a track's worktree, so usage rolls up per project no matter which worktree ran it.
    private let projectPath: String
    private let bridgeProvider: (String) -> WorkspaceBridge
    /// Resolves the directory a track's tools should actually operate in — its linked worktree
    /// if it has one, else the shared project root. Resolved fresh per tool call (see
    /// `AgentRunner`), not cached, so a track lazily materializing its worktree mid-session is
    /// picked up without any explicit invalidation.
    private let rootProvider: (String) -> URL
    /// Whether a track has opted into skipping approval for `run_shell_command` — resolved
    /// fresh per tool call, same as `rootProvider`, so toggling it mid-conversation takes effect
    /// on the very next command rather than requiring a fresh runner.
    /// The track's mode (tool scope × autonomy), resolved fresh per request.
    private let modeProvider: (String) -> AgentMode
    /// Per-track provider/model/effort, resolved fresh per request — same reasoning as
    /// `rootProvider`.
    private let modelSelectionProvider: (String) -> (providerId: String?, modelId: String?, effort: AgentEffort?)
    /// One harness per track. Today always Heron's `AgentRunner`; the Agent Client Protocol client
    /// joins it here when a track picks an outside agent (`SIDE_RFC_BYO_HARNESS.md`).
    private var runners: [String: any Harness] = [:]
    /// The outside agent a track runs on, nil for Heron. Set by the app, which stores the choice
    /// on the track.
    public var agentProvider: ((String) -> ACPAgent?)?
    /// Finds an agent's executable (login-shell PATH) and its spawn environment. Called off-main.
    public var acpLaunchProvider: (@Sendable (ACPAgent) -> ACPLaunch?)?
    /// Where outside agents' `terminal/*` requests run — the project's Run terminals. Nil means
    /// Side doesn't offer terminals, and the agent runs commands itself.
    public weak var acpTerminalHost: ACPTerminalHost?
    /// A track's remembered choices for its outside agent (option id → value), and where a new
    /// choice is recorded — so a model or mode picked once survives new conversations and relaunch.
    public var agentOptionsProvider: ((String) -> [String: String])?
    public var agentOptionChanged: ((String, String, String) -> Void)?
    /// Multi-agent (RFC step 2): creates and reads subtracks for coordinator tracks.
    public weak var trackCoordinator: (any TrackCoordinating)?

    /// The coordinator for a track that may use it.
    func coordinator(for trackKey: String) -> (any TrackCoordinating)? {
        guard let trackCoordinator, trackCoordinator.canCoordinate(trackKey: trackKey) else { return nil }
        return trackCoordinator
    }

    /// Fires whenever any owned runner's phase or unseen-completion state changes, debounced so
    /// a Tracks ledger or stage badge driven by many runners doesn't relayout on every single
    /// streamed token — only Think, watching one specific runner, needs per-event granularity.
    /// A multicast (same shape as `TrackStore.addChangeObserver`), not a single closure: this
    /// manager is shared across every window that has the project open, and a plain
    /// single-assignment callback would let the last window's registration silently clobber
    /// every other window's.
    private var changeObservers: [UUID: () -> Void] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.2

    public init(sessionStore: AgentSessionStore, projectPath: String, bridgeProvider: @escaping (String) -> WorkspaceBridge, rootProvider: @escaping (String) -> URL, modeProvider: @escaping (String) -> AgentMode, modelSelectionProvider: @escaping (String) -> (providerId: String?, modelId: String?, effort: AgentEffort?), trackContextProvider: @escaping (String) -> [AgentTrackSummary] = { _ in [] }) {
        self.sessionStore = sessionStore
        self.projectPath = projectPath
        self.bridgeProvider = bridgeProvider
        self.rootProvider = rootProvider
        self.modeProvider = modeProvider
        self.modelSelectionProvider = modelSelectionProvider
        self.trackContextProvider = trackContextProvider
    }
    private let trackContextProvider: (String) -> [AgentTrackSummary]

    @discardableResult
    public func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    public func removeChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    private func scheduleChangeNotification() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for observer in self.changeObservers.values { observer() }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    /// Branch-name key, `""` for "no active track" — same convention every other per-track store
    /// in this codebase already uses. Creating one wires it into the debounced multicast above
    /// for the rest of its life — no separate teardown needed, since that observer closure is
    /// only ever referenced by this manager, not by any external caller.
    public func runner(forTrackKey trackKey: String) -> any Harness {
        visited(trackKey)
        if let existing = runners[trackKey] {
            (existing as? AgentRunner)?.restoreTranscriptIfDropped()
            return existing
        }
        if let agent = agentProvider?(trackKey), let launch = acpLaunchProvider {
            let harness = ACPHarness(trackKey: trackKey, agent: agent, launchProvider: { launch(agent) },
                                     rootProvider: { [rootProvider] in rootProvider(trackKey) },
                                     bridgeProvider: { [bridgeProvider] in bridgeProvider(trackKey) },
                                     modeProvider: { [modeProvider] in modeProvider(trackKey) },
                                     sessionStore: sessionStore,
                                     terminalHost: { [weak self] in self?.acpTerminalHost },
                                     preferredOptions: { [weak self] in self?.agentOptionsProvider?(trackKey) ?? [:] },
                                     onOptionChanged: { [weak self] id, value in self?.agentOptionChanged?(trackKey, id, value) },
                                     toolServer: .shared,
                                     trackContext: { [weak self] in self?.trackContextProvider(trackKey) ?? [] },
                                     coordinatorProvider: { [weak self] in self?.coordinator(for: trackKey) },
                                     usageProjectPath: projectPath)
            harness.addObserver { [weak self] event in
                guard case .phaseChanged = event else { return }
                self?.scheduleChangeNotification()
            }
            runners[trackKey] = harness
            return harness
        }
        let runner = AgentRunner(
            trackKey: trackKey,
            sessionStore: sessionStore,
            projectPath: projectPath,
            bridgeProvider: { [bridgeProvider] in bridgeProvider(trackKey) },
            rootProvider: { [rootProvider] in rootProvider(trackKey) },
            modeProvider: { [modeProvider] in modeProvider(trackKey) },
            modelSelectionProvider: { [modelSelectionProvider] in modelSelectionProvider(trackKey) },
            trackContextProvider: { [trackContextProvider] in trackContextProvider(trackKey) }
        )
        runner.coordinatorProvider = { [weak self] in self?.coordinator(for: trackKey) }
        runner.addObserver { [weak self] event in
            guard case .phaseChanged = event else { return }
            self?.scheduleChangeNotification()
        }
        runners[trackKey] = runner
        return runner
    }

    /// Tracks by visit, most recent last. Heron's runners past the most recent
    /// `residentTranscripts` let go of their transcripts (D7): every visited track kept its
    /// whole transcript until the project closed, and the session store's own limit of three
    /// bounded nothing while the runners held a copy.
    private var visits: [String] = []
    static let residentTranscripts = 3

    private func visited(_ trackKey: String) {
        visits.removeAll { $0 == trackKey }
        visits.append(trackKey)
        for key in visits.dropLast(Self.residentTranscripts) {
            (runners[key] as? AgentRunner)?.dropTranscript()
        }
    }

    /// Non-creating peek — a track that's never had an agent run shouldn't spin one up just to
    /// ask "what's its activity," which would always answer `.none` anyway.
    public func existingRunner(forTrackKey trackKey: String) -> (any Harness)? {
        runners[trackKey]
    }

    /// An agent's sign-in changed (Settings › Agents): its idle conversations are put away so the
    /// next message launches it with the new account. Busy ones are left to finish. Returns the
    /// track keys that were restarted.
    @discardableResult
    public func restartAgent(id: String) -> [String] {
        var restarted: [String] = []
        for (key, runner) in runners where agentProvider?(key)?.id == id {
            guard !runner.phase.isBusy, runner.phase != .awaitingApproval else { continue }
            runner.teardown()
            runners.removeValue(forKey: key)
            restarted.append(key)
        }
        return restarted
    }

    /// Called when a track is deleted — its conversation has nowhere to belong anymore, same
    /// cleanup contract as Make's file memory and Run's terminal sessions.
    public func discardRunner(forTrackKey trackKey: String) {
        visits.removeAll { $0 == trackKey }
        guard let runner = runners.removeValue(forKey: trackKey) else { return }
        runner.teardown()
    }

    /// Called once, when the last window watching this project releases it (see
    /// `ProjectContextRegistry.release`) — never on an ordinary stage or track switch, which is
    /// exactly the bug this whole extraction fixes.
    public func teardownAll() {
        for runner in runners.values { runner.teardown() }
        runners.removeAll()
    }
}
