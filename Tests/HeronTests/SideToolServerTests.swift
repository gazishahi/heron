import XCTest
@testable import Heron

/// Multi-agent RFC step 1: Side's track tools over MCP, for outside agents.
@MainActor
final class SideToolServerTests: XCTestCase {
    private func post(_ url: URL, _ body: [String: Any]) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnAgentSeesTheTrackToolsThroughItsOwnURLOnly() async throws {
        let server = SideToolServer()
        let tracks = [AgentTrackSummary(branchName: "feature-a", intent: "Add billing", status: "active", baseRef: "main", isCurrent: true, gitDirectory: "/nonexistent")]
        let registration = try XCTUnwrap(server.register(.init(trackKey: "feature-a", tracks: { tracks })))
        XCTAssertEqual(registration.url.host, "127.0.0.1")

        let (_, initialize) = try await post(registration.url, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual((initialize?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let (accepted, _) = try await post(registration.url, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(accepted, 202)

        let (_, list) = try await post(registration.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["list_tracks", "read_track_overlap"])

        let (_, call) = try await post(registration.url, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_tracks", "arguments": [String: Any]()]])
        let text = (((call?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("feature-a [active] Add billing"), text)

        // Someone else's (or a guessed) path, a GET, and an ended conversation are all refused.
        var wrong = URLComponents(url: registration.url, resolvingAgainstBaseURL: false)!
        wrong.path = "/mcp/not-a-token"
        let (notFound, _) = try await post(wrong.url!, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        XCTAssertEqual(notFound, 404)
        var get = URLRequest(url: registration.url)
        get.httpMethod = "GET"
        let (_, getResponse) = try await URLSession.shared.data(for: get)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 405)
        server.unregister(token: registration.token)
        let (gone, _) = try await post(registration.url, ["jsonrpc": "2.0", "id": 5, "method": "tools/list"])
        XCTAssertEqual(gone, 404)
    }

    /// An agent that takes HTTP MCP servers is handed Side's with its session; one that doesn't
    /// isn't.
    func testSessionsCarrySidesToolsWhenTheAgentTakesThem() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        for takesHTTP in [true, false] {
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("mock-mcp-\(UUID().uuidString).py")
            try """
import json, sys
def send(m): sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method")
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"mcpCapabilities": {"http": \(takesHTTP ? "True" : "False")}}}})
    elif meth == "session/new":
        servers = m["params"]["mcpServers"]
        got = ",".join(s.get("type", "") + ":" + s.get("name", "") for s in servers) or "none"
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s", "configOptions": [{"id": "got", "name": "Got", "type": "select", "currentValue": got, "options": [{"value": got, "name": got}]}]}})
""".write(to: script, atomically: true, encoding: .utf8)
            let agent = ACPAgent(id: "mock-mcp-\(takesHTTP)", displayName: "Mock", binary: "mock", installHint: "")
            defer { UserDefaults.standard.removeObject(forKey: "SideACPKnownOptions.\(agent.id)") }
            let h = ACPHarness(trackKey: "t", agent: agent,
                               launchProvider: { ACPLaunch(executable: python, arguments: [script.path], environment: ProcessInfo.processInfo.environment) },
                               rootProvider: { FileManager.default.temporaryDirectory }, toolServer: SideToolServer())
            h.prepareSession()
            let expected = takesHTTP ? "http:side" : "none"
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, h.agentOptions.first?.current != expected { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(h.agentOptions.first?.current, expected)
            h.teardown()
        }
    }
}
