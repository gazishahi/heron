import Foundation
import Network

/// Side's own tools for outside agents, served over MCP (`SIDE_RFC_MULTI_AGENT.md`, step 1).
///
/// Heron calls Side's tools directly; an outside agent (Claude Code, Codex, Gemini) only knows
/// the tools its own harness has, plus any MCP servers the client hands it when a session opens.
/// This is that server: Streamable HTTP on 127.0.0.1, one unguessable URL per conversation, so an
/// agent can call exactly the tools of the track it's working on and nothing else.
///
/// Step 1 serves the read-only track tools (`list_tracks`, `read_track_overlap`, RFC R4), the
/// same implementations Heron's `ToolExecutor` uses. Later steps add the subtrack tools.
public final class SideToolServer: @unchecked Sendable {
    public static let shared = SideToolServer()

    /// One conversation's tools: the track they belong to, and how to read the project's tracks
    /// (main-actor state, snapshotted on the main thread for each call).
    public struct Registration: Sendable {
        public let trackKey: String
        public let tracks: @MainActor @Sendable () -> [AgentTrackSummary]
        /// The coordinator's tools, when this track may coordinate (step 2).
        public let coordination: CoordinationBridge?
        public let agentChoices: [(id: String, name: String)]
        /// Asks the user before a coordinator action (M1, M2): (tool, card title, whether Full may
        /// skip the card). The conversation shows a card unless Full may skip it or the user
        /// already allowed this call on the agent's own card.
        public let authorize: (@Sendable (String, String, Bool, @escaping @Sendable (Bool) -> Void) -> Void)?
        public init(trackKey: String, tracks: @escaping @MainActor @Sendable () -> [AgentTrackSummary], coordination: CoordinationBridge? = nil,
                    agentChoices: [(id: String, name: String)] = [],
                    authorize: (@Sendable (String, String, Bool, @escaping @Sendable (Bool) -> Void) -> Void)? = nil) {
            self.trackKey = trackKey
            self.tracks = tracks
            self.coordination = coordination
            self.agentChoices = agentChoices
            self.authorize = authorize
        }
    }

    private let queue = DispatchQueue(label: "side.tool-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var registrations: [String: Registration] = [:]

    public init() {}

    /// Registers a conversation and returns the URL its agent should use, starting the server on
    /// first use. Nil if it can't listen.
    public func register(_ registration: Registration) -> (url: URL, token: String)? {
        guard let port = ensureListening() else { return nil }
        let token = (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined()
        lock.withLock { registrations[token] = registration }
        return (URL(string: "http://127.0.0.1:\(port)/mcp/\(token)")!, token)
    }

    /// The conversation ended: its URL stops answering.
    public func unregister(token: String) {
        lock.withLock { _ = registrations.removeValue(forKey: token) }
    }

    // MARK: Listening

    private func ensureListening() -> UInt16? {
        if let port = lock.withLock({ port }) { return port }
        let parameters = NWParameters.tcp
        // Loopback only: nothing off this machine can reach it.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        guard let bound = listener.port?.rawValue, bound != 0 else { listener.cancel(); return nil }
        lock.withLock {
            self.listener = listener
            self.port = bound
        }
        return bound
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads one HTTP request (headers, then `Content-Length` bytes), answers it, closes.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                self.handle(request) { status, body in self.reply(connection, status: status, body: body) }
                return
            }
            if error != nil || isComplete || buffer.count > 4 * 1024 * 1024 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" } else { head += "Content-Length: 0\r\n" }
        var data = Data((head + "\r\n").utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: MCP

    private func handle(_ request: HTTPRequest, respond: @escaping @Sendable (Int, Data?) -> Void) {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "mcp", let registration = lock.withLock({ registrations[parts[1]] }) else {
            return respond(404, nil)
        }
        // Streamable HTTP: requests are POSTed; this server offers no server-initiated stream.
        guard request.method == "POST" else { return respond(405, nil) }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = message["method"] as? String else { return respond(400, nil) }
        guard let rawId = message["id"] else { return respond(202, nil) } // a notification
        // The request id is a JSON number or string; boxed so the reply can be sent from the
        // queue that finishes the work.
        let id = JSONBox(rawId)
        let result: @Sendable ([String: Any]) -> Void = { value in
            respond(200, try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id.value, "result": value]))
        }
        let failure: @Sendable (Int, String) -> Void = { code, text in
            respond(200, try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id.value, "error": ["code": code, "message": text]]))
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "side", "title": "Side", "version": "1"],
                "instructions": "Side's tools for the track you are working on: see the project's other tracks and which files you share with them.",
            ])
        case "ping":
            result([:])
        case "tools/list":
            var tools: [[String: Any]] = Self.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": ["type": "object", "properties": [String: Any]()]] }
            if registration.coordination != nil {
                for spec in CoordinationBridge.toolSpecs(agentChoices: registration.agentChoices) {
                    tools.append(["name": spec.name, "description": spec.description, "inputSchema": Self.plain(spec.inputSchema)])
                }
            }
            result(["tools": tools])
        case "tools/call" where registration.coordination != nil && CoordinationBridge.toolSpecs().contains(where: { $0.name == params["name"] as? String }):
            guard let bridge = registration.coordination, let name = params["name"] as? String else { return }
            let input = Self.jsonValue(params["arguments"] ?? [String: Any]())
            let text: @Sendable (String, Bool) -> Void = { output, isError in result(["content": [["type": "text", "text": output]], "isError": isError]) }
            DispatchQueue.global(qos: .userInitiated).async {
                switch name {
                case "create_subtrack":
                    if let refusal = bridge.refusal() { return text(refusal, true) }
                    switch bridge.request(from: input) {
                    case .failure(let error): text(error.message, true)
                    case .success(let request):
                        let agentName = registration.agentChoices.first { $0.id == (request.agentId ?? "heron") }?.name ?? "Heron"
                        guard let authorize = registration.authorize else { return text("Side can't ask the user here, so no subtrack was created.", true) }
                        authorize(name, "Create subtrack \u{201C}\(request.intent)\u{201D} on \(agentName)", true) { allowed in
                            guard allowed else { return text("The user declined. No subtrack was created.", false) }
                            bridge.create(request) { text($0, false) }
                        }
                    }
                case "promote_subtrack":
                    guard case .object(let object) = input, case .string(let track)? = object["track"] else { return text("promote_subtrack needs a track.", true) }
                    switch bridge.promotionCheck(track: track) {
                    case .failure(let error): text(error.message, true)
                    case .success(let check):
                        guard let authorize = registration.authorize else { return text("Side can't ask the user here, so nothing was promoted.", true) }
                        authorize(name, "Promote subtrack \u{201C}\(check.facts.intent)\u{201D} into this track", check.fullMayApply) { allowed in
                            guard allowed else { return text("The user declined. Nothing was promoted." + (check.note.isEmpty ? "" : " " + check.note), false) }
                            bridge.promote(track: track) { text($0, false) }
                        }
                    }
                default:
                    let outcome = bridge.run(name, input: input) ?? ("Unknown tool.", true)
                    text(outcome.output, outcome.isError)
                }
            }
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0.name == name }) else {
                return failure(-32602, "Unknown tool.")
            }
            let registration = registration
            DispatchQueue.main.async {
                let tracks = MainActor.assumeIsolated { registration.tracks() }
                // git, one call per track: off the main thread, like Heron's executor.
                DispatchQueue.global(qos: .userInitiated).async {
                    let text = Self.run(name, tracks: tracks)
                    result(["content": [["type": "text", "text": text]], "isError": false])
                }
            }
        default:
            failure(-32601, "Side doesn't offer \(method).")
        }
    }

    static let tools: [(name: String, description: String)] = [
        ("list_tracks", "List the other tracks in this project: each one's branch, status, intent, base branch, and how many files it has changed. Read-only. Use it to understand what else is in flight before planning a change that touches shared code."),
        ("read_track_overlap", "Which other tracks in this project have changed the same files as this track, and which files. Read-only. A shared file is a merge conflict waiting to happen at promotion; check before editing files another track is in the middle of."),
    ]

    /// A `JSONValue` schema as plain JSON for the wire.
    static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let items): return items.map(plain)
        case .object(let object): return object.mapValues(plain)
        }
    }

    /// Plain JSON from the wire as a `JSONValue`, for the tools' argument parsing.
    static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case let string as String: return .string(string)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: return .array(array.map(jsonValue))
        case let object as [String: Any]: return .object(object.mapValues(jsonValue))
        default: return .null
        }
    }

    static func run(_ name: String, tracks: [AgentTrackSummary]) -> String {
        switch name {
        case "list_tracks":
            return TrackContextTools.listing(tracks, changedPaths: ToolExecutor.changedPaths)
        default:
            guard let current = tracks.first(where: \.isCurrent) else {
                return "This conversation isn't attached to a track, so there is nothing to compare."
            }
            return TrackContextTools.overlapReport(current: current, all: tracks, changedPaths: ToolExecutor.changedPaths)
        }
    }
}

private struct JSONBox: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Just enough HTTP/1.1 for a local MCP client: request line, headers, `Content-Length` body.
private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// Nil until the whole request has arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" { length = Int(pair[1]) ?? 0 }
        }
        let bodyStart = end.upperBound
        guard length >= 0, data.count - bodyStart >= length else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1]).components(separatedBy: "?").first ?? ""
        body = data[bodyStart..<(bodyStart + length)]
    }
}
