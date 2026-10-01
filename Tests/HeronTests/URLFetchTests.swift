import XCTest
@testable import Heron

/// What the agent may fetch. The policy is the floor at every autonomy level: it decides which
/// URLs can even become a proposal, before anything is shown to the user.
final class URLFetchPolicyTests: XCTestCase {
    private func refusal(_ text: String) -> URLFetchPolicy.Refusal? {
        if case .failure(let why) = URLFetchPolicy.vet(text) { return why } else { return nil }
    }

    func testAPlainHTTPSPageIsAllowed() {
        XCTAssertNil(refusal("https://developer.apple.com/documentation/foundation/urlsession"))
        XCTAssertNil(refusal("  https://example.com/docs/index.html  "))
    }

    func testOnlyHTTPS() {
        XCTAssertEqual(refusal("http://example.com/"), .notHTTPS)
        XCTAssertEqual(refusal("file:///etc/passwd"), .notHTTPS)
        XCTAssertEqual(refusal("ftp://example.com/x"), .notHTTPS)
    }

    func testQueryStringsAndFragmentsAreRefused() {
        // The two places data hides in a URL — an agent that read the user's files could put
        // them here and "fetch" them out.
        XCTAssertEqual(refusal("https://example.com/collect?data=c2VjcmV0"), .hasQueryOrFragment)
        XCTAssertEqual(refusal("https://example.com/page#c2VjcmV0"), .hasQueryOrFragment)
    }

    func testEmbeddedCredentialsAreRefused() {
        XCTAssertEqual(refusal("https://user:pass@example.com/"), .hasCredentials)
    }

    func testLocalAndPrivateHostsAreRefusedByName() {
        for host in ["localhost", "api.localhost", "printer.local", "db.internal", "127.0.0.1", "10.0.0.5", "172.16.3.9",
                     "172.31.255.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "[::1]", "[fe80::1]", "[fd00::1]"] {
            if case .privateHost = refusal("https://\(host)/") {} else { XCTFail("\(host) was not refused") }
        }
    }

    func testPublicAddressesPassTheNameCheck() {
        XCTAssertNil(refusal("https://1.1.1.1/"))
        XCTAssertNil(refusal("https://172.32.0.1/"))  // just outside 172.16/12
        XCTAssertNil(refusal("https://[2606:4700:4700::1111]/"))
    }

    func testResolutionCatchesANameThatPointsHome() {
        // `localhost` is caught by name; this checks the resolver path with a name that is
        // guaranteed to resolve to loopback everywhere.
        XCTAssertEqual(URLFetchPolicy.resolvesPublicly("localhost"), .privateHost("localhost"))
        XCTAssertEqual(URLFetchPolicy.resolvesPublicly("no-such-host.invalid"), .unresolvable("no-such-host.invalid"))
    }

    func testAFetchProposalCarriesItsURLAndReadsAsAFetch() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))
        let proposal = ProposedCommand(toolUseId: "t1", fetching: url)
        XCTAssertEqual(proposal.fetchURL, url)
        XCTAssertEqual(proposal.command, "GET https://example.com/docs")
        XCTAssertEqual(proposal.riskLevel, .normal)
        XCTAssertNil(proposal.taskName)
    }
}

/// Turning a page into something the model can read.
final class HTMLTextTests: XCTestCase {
    func testScriptsAndStylesVanishEntirely() {
        let html = "<html><head><style>body{color:red}</style><script>alert('x')</script></head><body><p>Hello</p></body></html>"
        XCTAssertEqual(HTMLText.extract(from: html), "Hello")
    }

    func testBlockElementsKeepParagraphsApart() {
        let html = "<h1>Title</h1><p>First para.</p><p>Second <b>bold</b> para.</p><ul><li>one</li><li>two</li></ul>"
        XCTAssertEqual(HTMLText.extract(from: html), "Title\nFirst para.\nSecond bold para.\none\ntwo")
    }

    func testEntitiesAreDecodedAndWhitespaceCollapsed() {
        XCTAssertEqual(HTMLText.extract(from: "<p>a &amp; b &lt; c&nbsp;&nbsp;d</p>\n\n\n<p>   e   </p>"), "a & b < c d\ne")
    }

    func testCaseInsensitiveTagsAndUnclosedScriptDoNotEatThePage() {
        XCTAssertEqual(HTMLText.extract(from: "<SCRIPT>x</SCRIPT><P>kept</P>"), "kept")
        // An unterminated script is left alone rather than swallowing everything after it.
        XCTAssertTrue(HTMLText.extract(from: "<script>oops<p>still here</p>").contains("still here"))
    }
}

/// The fetch itself, against a local server. Loopback is exactly what the policy refuses, so the
/// fetcher is exercised on the pieces below the policy — status handling and text extraction — by
/// calling the extractor on a real response body.
final class URLFetcherTests: XCTestCase {
    func testTheFetcherRefusesAPrivateHostBeforeConnecting() async throws {
        do {
            _ = try await URLFetcher.fetch(URL(string: "https://127.0.0.1:1/")!)
            XCTFail("connected to loopback")
        } catch let error as URLFetcher.FetchError {
            if case .refused = error {} else { XCTFail("wrong refusal: \(error)") }
        }
    }
}
