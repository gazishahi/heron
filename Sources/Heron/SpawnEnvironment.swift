import Foundation

/// The environment every child process starts with: Side's own, without the secrets in it. Side
/// supports `ANTHROPIC_API_KEY` in its environment, and before this every child got it, and any
/// other key there too: language servers, debug adapters and the programs they start, git, gh,
/// builds, installers, and other vendors' agents (2026-09-30 audit, SEC-14). A child that needs
/// one of these gets it back by name (`keeping`); an outside agent gets its own key from
/// `ACPAgent.launchEnvironment`, in API-key mode only. The terminal is the exception: it's the
/// person's own shell, and keeps their environment.
public enum SpawnEnvironment {
    /// Side's environment, scrubbed.
    public static func current(keeping: Set<String> = []) -> [String: String] {
        scrubbed(ProcessInfo.processInfo.environment, keeping: keeping)
    }

    public static func scrubbed(_ environment: [String: String], keeping: Set<String> = []) -> [String: String] {
        environment.filter { name, _ in keeping.contains(name) || !isSecret(name) }
    }

    /// Whether a variable's name says it holds a credential: `…_API_KEY`, `…_TOKEN`, `…_SECRET`,
    /// passwords, access and private keys. Not `SSH_AUTH_SOCK`, a socket path git needs to push.
    public static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return markers.contains { upper.contains($0) }
    }

    private static let markers = ["API_KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD",
                                  "CREDENTIAL", "ACCESS_KEY", "PRIVATE_KEY", "AUTH_KEY"]
}
