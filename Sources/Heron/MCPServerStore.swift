import Foundation

/// One of the user's own MCP servers (Library, `SIDE_RFC_LIBRARY.md` step 2). A local program
/// the agent starts over stdio, which every ACP agent supports.
public struct MCPServerConfig: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var command: String
    public var arguments: [String]
    /// The names of its environment variables. The values are secrets and live in the Keychain.
    public var environmentNames: [String]
    /// Project roots it's switched on for (L1: the user's servers, enabled per project).
    public var enabledProjects: [String]

    public func isEnabled(forProject path: String) -> Bool {
        enabledProjects.contains(MCPServerStore.projectKey(path))
    }
}

/// The user's MCP servers, and what an outside agent is handed for a project. Never read from a
/// repository: a cloned repo must not be able to start a program on the user's machine.
public enum MCPServerStore {
    public static let didChangeNotification = Notification.Name("SideMCPServersDidChange")
    /// Where this type persists. Tests point it at a private suite.
    public nonisolated(unsafe) static var defaults: UserDefaults = .standard
    private static let key = "SideMCPServers"
    /// The name Side's own tool server goes by, so a user's server can't shadow it.
    public static let reservedName = "side"

    public static var all: [MCPServerConfig] {
        guard let data = defaults.data(forKey: key),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return [] }
        return servers
    }

    public static func projectKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// Adds or replaces a server. `environment` nil keeps the stored values.
    @discardableResult
    public static func save(_ server: MCPServerConfig, environment: [String: String]?) -> MCPServerConfig {
        var server = server
        server.name = uniqueName(server.name, excluding: server.id)
        if let environment {
            let values = environment.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            server.environmentNames = values.keys.sorted()
            if values.isEmpty { KeychainStore.delete(account: account(server.id)) }
            else if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
                KeychainStore.set(secret: text, account: account(server.id))
            }
        }
        var servers = all
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        write(servers)
        return server
    }

    public static func newServer(name: String, command: String, arguments: [String]) -> MCPServerConfig {
        MCPServerConfig(id: UUID().uuidString.lowercased(), name: name, command: command, arguments: arguments, environmentNames: [], enabledProjects: [])
    }

    public static func remove(id: String) {
        KeychainStore.delete(account: account(id))
        write(all.filter { $0.id != id })
    }

    public static func setEnabled(_ enabled: Bool, id: String, projectPath: String) {
        var servers = all
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let project = projectKey(projectPath)
        servers[index].enabledProjects.removeAll { $0 == project }
        if enabled { servers[index].enabledProjects.append(project) }
        write(servers)
    }

    public static func environment(for id: String) -> [String: String] {
        guard let text = KeychainStore.get(account: account(id)), let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    public static func enabled(forProject path: String) -> [MCPServerConfig] {
        all.filter { $0.isEnabled(forProject: path) }
    }

    /// ACP `mcpServers` entries (stdio) for a project. A bare command is resolved against
    /// `searchPath`, the PATH the agent was launched with: ACP asks for a path to the executable.
    public static func acpDescriptors(forProject path: String, searchPath: String?) -> [[String: Any]] {
        enabled(forProject: path).map { server in
            let environment = environment(for: server.id)
            return [
                "name": server.name,
                "command": resolve(server.command, searchPath: searchPath),
                "args": server.arguments,
                "env": environment.keys.sorted().map { ["name": $0, "value": environment[$0] ?? ""] },
            ]
        }
    }

    static func resolve(_ command: String, searchPath: String?) -> String {
        let expanded = (command as NSString).expandingTildeInPath
        guard !expanded.contains("/") else { return expanded }
        for directory in (searchPath ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + expanded
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return expanded
    }

    /// Splits an arguments field the way a shell would for the simple cases: spaces separate,
    /// quotes group.
    public static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character == " " || character == "\t" {
                if hasToken || !current.isEmpty { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
            }
        }
        if hasToken || !current.isEmpty { result.append(current) }
        return result
    }

    private static func uniqueName(_ name: String, excluding id: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "server" : name.trimmingCharacters(in: .whitespaces)
        let taken = Set(all.filter { $0.id != id }.map { $0.name.lowercased() } + [reservedName])
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func account(_ id: String) -> String { "mcp.\(id)" }

    private static func write(_ servers: [MCPServerConfig]) {
        defaults.set(try? JSONEncoder().encode(servers), forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
