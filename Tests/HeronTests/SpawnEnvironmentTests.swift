import XCTest
@testable import Heron

/// SEC-14 (2026-09-30 audit): what a child process doesn't get from Side's environment.
final class SpawnEnvironmentTests: XCTestCase {
    func testSecretsAreRemovedAndTheRestKept() {
        let environment = ["PATH": "/bin", "HOME": "/Users/x", "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "en_US.UTF-8",
                           "ANTHROPIC_API_KEY": "a", "OPENAI_API_KEY": "b", "GH_TOKEN": "c", "AWS_SECRET_ACCESS_KEY": "d",
                           "AWS_SESSION_TOKEN": "e", "PGPASSWORD": "f", "GOOGLE_APPLICATION_CREDENTIALS": "g", "npm_config__authToken": "h"]
        XCTAssertEqual(SpawnEnvironment.scrubbed(environment),
                       ["PATH": "/bin", "HOME": "/Users/x", "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "en_US.UTF-8"])
        XCTAssertEqual(SpawnEnvironment.scrubbed(environment, keeping: ["GH_TOKEN"])["GH_TOKEN"], "c")
    }

    /// Git, which Heron runs, starts without the key.
    func testGitGetsNoKeys() throws {
        setenv("SIDE_TEST_API_KEY", "leak", 1)
        defer { unsetenv("SIDE_TEST_API_KEY") }
        let result = GitPaths.runGit(["-c", "alias.env=!printenv SIDE_TEST_API_KEY; echo done", "env"], cwd: NSTemporaryDirectory())
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    /// UX-14: with no choice made, an agent whose key is exported uses it; Claude Code doesn't.
    func testAnExportedKeyIsTheDefaultSignInExceptForClaudeCode() {
        setenv("SIDE_TEST_AGENT_KEY", "k", 1)
        defer { unsetenv("SIDE_TEST_AGENT_KEY") }
        let gemini = ACPAgent(id: "gemini", displayName: "G", binary: "g", installHint: "", apiKeyVariables: ["SIDE_TEST_AGENT_KEY"])
        let claude = ACPAgent(id: "claude-code", displayName: "C", binary: "c", installHint: "", apiKeyVariables: ["SIDE_TEST_AGENT_KEY"])
        let unset = ACPAgent(id: "codex", displayName: "X", binary: "x", installHint: "", apiKeyVariables: ["SIDE_TEST_NO_SUCH_KEY"])
        XCTAssertEqual(gemini.defaultSignIn, .apiKey)
        XCTAssertEqual(claude.defaultSignIn, .subscription)
        XCTAssertEqual(unset.defaultSignIn, .subscription)
    }
}
