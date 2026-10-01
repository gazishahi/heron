import Foundation

/// An outside agent Side can drive over the Agent Client Protocol (`SIDE_RFC_BYO_HARNESS.md`).
/// The agent runs on the user's own account: their subscription through the agent's own login,
/// or an API key they give Side for it. Side launches their CLI; it never proxies either.
public struct ACPAgent: Equatable, Sendable, Codable {
    /// Stable id, stored on the track.
    public let id: String
    public let displayName: String
    /// The executable to find on the login-shell PATH (or a full path, for a custom agent).
    public let binary: String
    public let arguments: [String]
    /// What to run if it isn't installed: shown to copy, never run for the user.
    public let installHint: String
    /// The environment variables the agent reads an API key from. The first is the one Side sets
    /// when the agent signs in with a key. All of them are removed when it signs in with the
    /// user's subscription, because an exported key silently wins over the login: Claude Code
    /// billed a stale key and hung (found 2026-09-23).
    public let apiKeyVariables: [String]
    /// What "sign in with your subscription" means for this agent, in its own words.
    public let subscriptionName: String
    /// Added by the user in Settings › Agents rather than shipped with Side.
    public let isCustom: Bool

    public init(id: String, displayName: String, binary: String, arguments: [String] = [], installHint: String,
                apiKeyVariables: [String] = [], subscriptionName: String = "The agent's own login", isCustom: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.arguments = arguments
        self.installHint = installHint
        self.apiKeyVariables = apiKeyVariables
        self.subscriptionName = subscriptionName
        self.isCustom = isCustom
    }

    /// Verified live with Side end to end (SIDE_RFC_BYO_HARNESS.md). The rest are shown as
    /// experimental until they are (launch gate 4; 2026-09-30 audit, H12).
    public static let verifiedIds: Set<String> = ["claude-code"]
    public var isVerified: Bool { Self.verifiedIds.contains(id) }

    /// The agents Side ships knowing how to launch. Claude Code, Codex and Pi speak ACP through
    /// small adapters; Gemini CLI speaks it natively. Anything else in the ACP registry can be
    /// added as a custom agent.
    public static let builtIn: [ACPAgent] = [
        ACPAgent(id: "claude-code", displayName: "Claude Code", binary: "claude-agent-acp",
                 installHint: "npm install -g @agentclientprotocol/claude-agent-acp",
                 apiKeyVariables: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
                 subscriptionName: "Claude subscription (claude login)"),
        ACPAgent(id: "codex", displayName: "Codex", binary: "codex-acp",
                 installHint: "npm install -g @agentclientprotocol/codex-acp",
                 apiKeyVariables: ["CODEX_API_KEY", "OPENAI_API_KEY"],
                 subscriptionName: "ChatGPT account"),
        ACPAgent(id: "gemini", displayName: "Gemini CLI", binary: "gemini", arguments: ["--acp"],
                 installHint: "npm install -g @google/gemini-cli",
                 apiKeyVariables: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
                 subscriptionName: "Google account"),
        ACPAgent(id: "pi", displayName: "Pi", binary: "pi-acp",
                 installHint: "npm install -g pi-acp @earendil-works/pi-coding-agent",
                 subscriptionName: "Pi's own login"),
    ]

    /// Built-in agents, then the user's own.
    public static var known: [ACPAgent] { builtIn + custom }

    public static func agent(id: String?) -> ACPAgent? { known.first { $0.id == id } }

    // MARK: Custom agents

    private static let customKey = "SideACPCustomAgents"

    /// Where agents' settings live: the person's preferences, or under tests a suite of this
    /// process's own, gone when it exits. Parallel test processes read-modify-wrote the real
    /// list at once, so agents vanished mid-test and test agents were left in the owner's Side
    /// (2026-09-30 audit, TST-1).
    nonisolated(unsafe) public static let defaults: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestBundlePath"] != nil || environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil,
              let suite = UserDefaults(suiteName: testSuiteName) else { return .standard }
        suite.removePersistentDomain(forName: testSuiteName)
        atexit { UserDefaults.standard.removePersistentDomain(forName: ACPAgent.testSuiteName) }
        return suite
    }()
    static let testSuiteName = "com.shahi.side.tests.\(ProcessInfo.processInfo.processIdentifier)"

    public static var custom: [ACPAgent] {
        guard let data = defaults.data(forKey: customKey),
              let agents = try? JSONDecoder().decode([ACPAgent].self, from: data) else { return [] }
        return agents
    }

    /// Any ACP agent: a command and its arguments ("opencode" ["acp"], "goose" ["acp"]…).
    @discardableResult
    public static func addCustom(name: String, command: String, arguments: [String], apiKeyVariable: String?) -> ACPAgent {
        let variable = apiKeyVariable?.trimmingCharacters(in: .whitespaces)
        let agent = ACPAgent(id: "custom-" + UUID().uuidString.lowercased(), displayName: name, binary: command, arguments: arguments,
                             installHint: "Install \(name) so that \u{201C}\(command)\u{201D} runs from your shell.",
                             apiKeyVariables: variable.map { $0.isEmpty ? [] : [$0] } ?? [], isCustom: true)
        saveCustom(custom + [agent])
        return agent
    }

    public static func removeCustom(id: String) {
        saveCustom(custom.filter { $0.id != id })
        defaults.removeObject(forKey: signInKey(id))
        KeychainStore.delete(account: keychainAccount(id))
    }

    private static func saveCustom(_ agents: [ACPAgent]) {
        defaults.set(try? JSONEncoder().encode(agents), forKey: customKey)
    }

    // MARK: Signing in

    public enum SignIn: String, Sendable, CaseIterable {
        /// The agent's own login: Claude, ChatGPT, Google… The user's subscription.
        case subscription
        /// An API key Side keeps in the Keychain and gives the agent in its environment.
        case apiKey
    }

    private static func signInKey(_ id: String) -> String { "SideACPSignIn.\(id)" }
    static func keychainAccount(_ id: String) -> String { "acp.\(id)" }

    public var signIn: SignIn {
        get { Self.defaults.string(forKey: Self.signInKey(id)).flatMap(SignIn.init(rawValue:)) ?? .subscription }
        nonmutating set { Self.defaults.set(newValue.rawValue, forKey: Self.signInKey(id)) }
    }

    /// Whether this agent can take a key at all (it names a variable to read it from).
    public var acceptsAPIKey: Bool { !apiKeyVariables.isEmpty }

    public var storedAPIKey: String? { KeychainStore.get(account: Self.keychainAccount(id)) }

    public func setAPIKey(_ key: String?) {
        if let key, !key.isEmpty { KeychainStore.set(secret: key, account: Self.keychainAccount(id)) }
        else { KeychainStore.delete(account: Self.keychainAccount(id)) }
    }

    /// The environment to launch the agent with, from the app's spawn environment. Subscription:
    /// every key variable removed, so the agent uses its login. API key: the stored key (or,
    /// without one, a key already in the environment) in the first variable, the rest removed.
    public func launchEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        let inherited = apiKeyVariables.lazy.compactMap { base[$0] }.first { !$0.isEmpty }
        for name in apiKeyVariables { environment.removeValue(forKey: name) }
        if signIn == .apiKey, let variable = apiKeyVariables.first, let key = storedAPIKey ?? inherited {
            environment[variable] = key
        }
        return environment
    }
}

/// How to start an agent process: resolved by the app, which owns login-shell PATH lookup.
public struct ACPLaunch: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// How the agent should sign in, for agents that ask (ACP `authenticate`).
    public let signIn: ACPAgent.SignIn

    public init(executable: URL, arguments: [String], environment: [String: String], signIn: ACPAgent.SignIn = .subscription) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.signIn = signIn
    }
}
