import Foundation

/// One Server-Sent Events frame: an optional `event:` name plus a `data:` payload.
public struct SSEEvent {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public enum SSEHTTPClientError: Error, LocalizedError {
    case notHTTP
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP:
            return "The response was not an HTTP response."
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        }
    }
}

/// The streaming transport Heron's provider adapters share — plays the same role
/// JSONRPCTransport's Content-Length parser plays for LSP, just for a different framing
/// (SSE `data:` lines over HTTP instead of length-prefixed frames over stdio). Provider-
/// agnostic: each adapter owns only its own request-building and payload parsing on top.
public enum SSEHTTPClient {
    /// A dedicated session, not `.shared` — its whole purpose is the explicit request timeout
    /// below, which `.shared`'s default configuration also happens to set to 60s but not in a
    /// way any caller here controls or can point to. `timeoutIntervalForRequest` resets on any
    /// received byte, so this is a "the connection produced literally nothing for 60s" backstop
    /// underneath `AgentRunner`'s own 90s stall watchdog, which instead watches for meaningful
    /// SSE events — the two catch different failure shapes (a dead TCP connection vs. a live one
    /// that stopped saying anything useful).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    /// Refuses every HTTP redirect.
    ///
    /// URLSession's default is to follow a 30x by re-issuing the original request — custom
    /// headers included — to wherever `Location` points. Both adapters put the user's API key in
    /// a header, so a bring-your-own-key base URL that redirects, a misconfigured endpoint, or an
    /// intercepting proxy could replay that key to a host the user never authorized. An SSE stream
    /// never legitimately redirects; the 3xx is delivered to the caller as an ordinary non-200 and
    /// surfaces as an HTTP error naming the status. (2026-09-01 audit, H2.)
    /// Also the model-list refresh's (`ProviderRegistryStore.refreshModels`), which sends the key too.
    final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
        public func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Streams `request`, invoking `onEvent` once per SSE frame, in order, from the caller's
    /// own task — no queue hopping happens here. Returns when the server closes the stream;
    /// throws for transport failures (connection refused/dropped, task cancellation) and for
    /// non-200 responses (with the response body captured, since providers put their error
    /// JSON there). Honors Swift task cancellation — cancelling the surrounding task tears
    /// down the connection mid-stream.
    ///
    /// Dispatches on each `data:` line rather than waiting for the blank-line frame
    /// terminator: every provider this client targets (Anthropic, OpenAI-compatible) sends
    /// one complete JSON payload per `data:` line, and not relying on empty lines sidesteps
    /// any ambiguity in how AsyncLineSequence reports them. Multi-line `data:` payloads are
    /// deliberately unsupported.
    public static func stream(request: URLRequest, onEvent: (SSEEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSEHTTPClientError.notHTTP }
        guard http.statusCode == 200 else {
            // The error body arrives on the same byte stream — collect it (bounded) so the
            // caller can surface the provider's actual message instead of a bare status code.
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 20_000 { break }
            }
            throw SSEHTTPClientError.httpError(statusCode: http.statusCode, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var currentEventName: String?
        for try await line in bytes.lines {
            if let event = SSEFraming.event(fromLine: line, eventName: &currentEventName) { onEvent(event) }
        }
    }
}

/// The per-line half of SSE parsing, kept pure so it can be tested without a socket.
public enum SSEFraming {
    /// Returns an event when `line` is a `data:` line; updates `eventName` on an `event:` line.
    /// Comment lines (":keepalive"), `id:`, `retry:`, and blank lines produce nothing, per the spec.
    public static func event(fromLine line: String, eventName: inout String?) -> SSEEvent? {
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            return SSEEvent(event: eventName, data: String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
