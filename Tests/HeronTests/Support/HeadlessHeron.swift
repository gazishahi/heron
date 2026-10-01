import Foundation
@testable import Heron

/// Heron's own runner with no app around it (SIDE_RFC_HERON_EFFICIENCY.md, step 1): a project
/// on disk, a registry and usage store of its own (never the person's), edits applied without a
/// click (Build, full autonomy) and commands refused. For the fake-server measurements and the
/// real-API benchmark alike.
@MainActor
final class HeadlessHeron {
    let project: URL
    let state: URL
    let registry: ProviderRegistryStore
    let usage: UsageStore
    let runner: AgentRunner
    let sessionStore: AgentSessionStore
    /// The conversation as stored.
    var turns: [AgentTurn] { sessionStore.session(forTrackKey: "")?.turns ?? [] }
    /// `baseURL` nil: the real Anthropic API, with `ANTHROPIC_API_KEY`.
    /// `contextWindow` shrinks the model's window, so a short scripted session reaches the
    /// sweep's and compaction's thresholds.
    init(project: URL, baseURL: URL?, modelId: String, mode: AgentMode, effort: AgentEffort = .standard, contextWindow: Int? = nil) throws {
        self.project = project
        state = FileManager.default.temporaryDirectory.appendingPathComponent("heron-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        registry = ProviderRegistryStore(storeURL: state.appendingPathComponent("providers.json"))
        if let baseURL, var anthropic = registry.provider(for: "anthropic") {
            anthropic.baseURL = baseURL
            if let contextWindow, let index = anthropic.models.firstIndex(where: { $0.id == modelId }) {
                anthropic.models[index].contextWindowTokens = contextWindow
            }
            registry.addOrUpdate(anthropic)
            // The fake server needs a key present, not a real one.
            if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil { setenv("ANTHROPIC_API_KEY", "fake", 1) }
        }
        usage = UsageStore(storeURL: state.appendingPathComponent("usage.json"))
        sessionStore = AgentSessionStore(stateDirectory: state.appendingPathComponent("sessions"))
        let root = project
        let bridge = WorkspaceBridge(
            liveBufferProvider: { _ in nil },
            applyEditIntoOpenTab: { _, _ in false },
            onRevealFileRequested: { _ in },
            runShellCommand: { _, _, completion in completion("Commands aren't run in the benchmark.") },
            interruptShellCommand: {}
        )
        runner = AgentRunner(
            trackKey: "", sessionStore: sessionStore, projectPath: project.path,
            bridgeProvider: { bridge }, rootProvider: { root }, modeProvider: { mode },
            modelSelectionProvider: { ("anthropic", modelId, effort) },
            providerRegistry: registry, usageStore: usage
        )
    }

    /// Sends one message and waits for the turn to end (finished, blocked, or failed).
    @discardableResult
    func send(_ text: String, timeout: TimeInterval = 300) -> AgentRunPhase {
        runner.send(text)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            // An edit waiting on approval can't happen at full autonomy; a command can: refuse it.
            if runner.phase == .awaitingApproval {
                // Resolved by the transcript entry's id, as Think's buttons do.
                for entry in runner.entries {
                    if case .commandProposal(let presentation) = entry.kind, presentation.resolution == nil {
                        runner.resolve(proposalId: entry.id, decision: .reject)
                    }
                    if case .proposal(let presentation) = entry.kind, presentation.resolution == nil {
                        runner.resolve(proposalId: entry.id, decision: .apply)
                    }
                }
            }
            switch runner.phase {
            case .finishedTurn, .blocked: return runner.phase
            case .idle where !runner.entries.isEmpty: return runner.phase
            default: continue
            }
        }
        return runner.phase
    }

    /// Totals from this run's own usage store.
    var totals: UsageTotals { usage.grandTotal() }

    func cleanUp() { try? FileManager.default.removeItem(at: state) }
}
