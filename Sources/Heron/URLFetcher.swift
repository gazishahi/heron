import Foundation

/// What `fetch_url` may reach, decided before any connection is made.
///
/// A URL is an outbound channel. An agent that has read the user's files can encode what it read
/// into a query string and "fetch" it — so a fetch is a *proposal* the user approves, exactly like
/// a command, and the autonomy setting decides whether one that passes these checks may run
/// unattended. The checks themselves are the floor at every autonomy level: only https, no
/// credentials in the URL, no query or fragment (the two places data hides in a URL), and never a
/// host that resolves to the machine or its network — a fetch of `http://localhost:…` is how an
/// agent reaches things the browser sandbox exists to keep it from.
public enum URLFetchPolicy {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notHTTPS, hasCredentials, hasQueryOrFragment, noHost, privateHost(String), unresolvable(String)

        public var description: String {
            switch self {
            case .notHTTPS: return "only https:// URLs can be fetched"
            case .hasCredentials: return "URLs with embedded credentials are refused"
            case .hasQueryOrFragment: return "URLs with a query string or fragment are refused. Fetch the page, not a parameterized endpoint"
            case .noHost: return "the URL has no host"
            case .privateHost(let host): return "\(host) is local or on a private network"
            case .unresolvable(let host): return "\(host) could not be resolved"
            }
        }
    }

    /// The URL, normalized, or why it may not be fetched. Does not touch the network.
    public static func vet(_ text: String) -> Result<URL, Refusal> {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = components.url else { return .failure(.noHost) }
        guard components.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQueryOrFragment) }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.noHost) }
        if isPrivateHostName(host) { return .failure(.privateHost(host)) }
        return .success(url)
    }

    /// Resolves the host and refuses if *any* address is local or private — a name with one public
    /// and one private address is exactly the DNS-rebinding shape this guards against.
    public static func resolvesPublicly(_ host: String) -> Refusal? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return .unresolvable(host) }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr, isPrivateAddress(address) { return .privateHost(host) }
            cursor = entry.pointee.ai_next
        }
        return nil
    }

    public static func isPrivateHostName(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        // Literal addresses are checked as addresses; anything else waits for resolution.
        var v4 = in_addr(); var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return isPrivateIPv4(v4) }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET6, bare, &v6) == 1 { return isPrivateIPv6(v6) }
        return false
    }

    private static func isPrivateAddress(_ address: UnsafeMutablePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { isPrivateIPv4($0.pointee.sin_addr) }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { isPrivateIPv6($0.pointee.sin6_addr) }
        default:
            return true
        }
    }

    private static func isPrivateIPv4(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let a = UInt8(value >> 24), b = UInt8((value >> 16) & 0xff)
        if a == 10 || a == 127 || a == 0 { return true }                 // 10/8, loopback, "this"
        if a == 172, (16...31).contains(b) { return true }               // 172.16/12
        if a == 192, b == 168 { return true }                            // 192.168/16
        if a == 169, b == 254 { return true }                            // link-local, cloud metadata
        if a == 100, (64...127).contains(b) { return true }              // carrier NAT
        return false
    }

    private static func isPrivateIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }          // ::1
        if bytes.allSatisfy({ $0 == 0 }) { return true }                              // ::
        if bytes[0] & 0xfe == 0xfc { return true }                                    // fc00::/7
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }                  // fe80::/10
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { // ::ffff:a.b.c.d
            return isPrivateIPv4(in_addr(s_addr: in_addr_t(bigEndian: UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))))
        }
        return false
    }
}

/// Fetches one page for the agent and turns it into text it can read.
public enum URLFetcher {
    /// Enough for a long documentation page; ToolExecutor caps what the model sees further.
    public static let maxBytes = 2_000_000
    public static let timeout: TimeInterval = 20

    /// Redirects are followed only to https on a host that also passes the policy — a public page
    /// must not be able to bounce the agent onto the local network.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let target = request.url, case .success = URLFetchPolicy.vet(target.absoluteString),
                  URLFetchPolicy.resolvesPublicly(target.host ?? "") == nil else { return completionHandler(nil) }
            completionHandler(request)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Side/1.0 (+agent fetch)", "Accept": "text/html, text/plain, application/json, text/markdown, application/xml;q=0.9, */*;q=0.1"]
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    public struct Page {
        public let finalURL: URL
        public let contentType: String
        public let text: String

        public init(finalURL: URL, contentType: String, text: String) {
            self.finalURL = finalURL
            self.contentType = contentType
            self.text = text
        }
    }

    public static func fetch(_ url: URL) async throws -> Page {
        if let refusal = URLFetchPolicy.resolvesPublicly(url.host ?? "") { throw FetchError.refused(refusal.description) }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.status(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw FetchError.tooLarge }
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let raw = String(decoding: data, as: UTF8.self)
        let text = contentType.contains("html") ? HTMLText.extract(from: raw) : raw
        return Page(finalURL: http.url ?? url, contentType: contentType, text: text)
    }

    public enum FetchError: Error, LocalizedError {
        case refused(String), notHTTP, status(Int), tooLarge
        public var errorDescription: String? {
            switch self {
            case .refused(let why): return "Refused: \(why)."
            case .notHTTP: return "The response was not HTTP."
            case .status(let code): return "The server answered HTTP \(code)."
            case .tooLarge: return "The page is larger than \(maxBytes / 1_000_000) MB; fetch something smaller."
            }
        }
    }
}

/// The readable text of an HTML page — no parser, no DOM, just the parts that were written to be
/// read. Scripts and styles go entirely; tags become whitespace; block-level closers become line
/// breaks so paragraphs stay paragraphs; a handful of entities are decoded; runs of whitespace
/// collapse. Good enough for documentation, which is what this is for.
public enum HTMLText {
    public static func extract(from html: String) -> String {
        var text = stripping(html, element: "script")
        text = stripping(text, element: "style")
        text = stripping(text, element: "noscript")
        var out = ""
        out.reserveCapacity(text.count)
        var inTag = false
        var tagName = ""
        for scalar in text.unicodeScalars {
            if inTag {
                if scalar == ">" {
                    inTag = false
                    let name = tagName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    let block = name.split(separator: " ").first.map(String.init) ?? name
                    if blockElements.contains(block) { out.append("\n") } else { out.append(" ") }
                    tagName = ""
                } else {
                    tagName.unicodeScalars.append(scalar)
                }
            } else if scalar == "<" {
                inTag = true
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return collapse(decodingEntities(out))
    }

    private static let blockElements: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "table", "section", "article",
        "header", "footer", "pre", "blockquote", "dd", "dt", "hr", "nav", "main", "aside",
    ]

    private static func stripping(_ html: String, element: String) -> String {
        var result = html
        let lower = result.lowercased()
        var searchFrom = lower.startIndex
        var ranges: [Range<String.Index>] = []
        while let open = lower.range(of: "<" + element, range: searchFrom..<lower.endIndex) {
            guard let close = lower.range(of: "</" + element, range: open.upperBound..<lower.endIndex),
                  let end = lower.range(of: ">", range: close.upperBound..<lower.endIndex) else { break }
            ranges.append(open.lowerBound..<end.upperBound)
            searchFrom = end.upperBound
        }
        for range in ranges.reversed() { result.removeSubrange(range) }
        return result
    }

    private static func decodingEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    /// One line per block, no blank lines: both the opening and closing tag of a block element
    /// emit a newline, so paragraphs would otherwise arrive double-spaced — pure token cost for
    /// the model, with nothing gained.
    private static func collapse(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
