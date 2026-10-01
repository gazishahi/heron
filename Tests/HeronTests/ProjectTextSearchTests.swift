import XCTest
@testable import Heron

/// The one search behind both the agent's `search_files` and the human's Find in Project.
final class ProjectTextSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "let alpha = 1\nlet Beta = 2\nfunc gamma() {}\n".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try "alpha again\nnothing here\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "ALPHA in ts\n".write(to: root.appendingPathComponent("src/b.ts"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func search(_ query: String, _ configure: (inout ProjectTextSearch.Options) -> Void = { _ in }, live: [String: String] = [:]) throws -> ProjectTextSearch.Results {
        var options = ProjectTextSearch.Options()
        configure(&options)
        return try ProjectTextSearch.search(root: root, query: query, options: options, liveBuffer: { url in live[url.lastPathComponent] })
    }

    func testSubstringSearch() throws {
        // Case-insensitive, one-based lines, the trimmed line as the match text — and an empty
        // query matches nothing rather than everything.
        let results = try search("alpha")
        let located = results.matches.map { "\($0.relativePath):\($0.line)" }.sorted()
        XCTAssertEqual(located, ["README.md:1", "src/a.swift:1", "src/b.ts:1"])
        XCTAssertFalse(results.truncated)

        let match = try search("gamma").matches.first
        XCTAssertEqual(match?.text, "func gamma() {}")
        XCTAssertEqual(match?.line, 3)

        XCTAssertTrue(try search("").matches.isEmpty)
    }

    func testRegexSearchAndInvalidRegex() throws {
        // Regex is case-insensitive, like the substring form — the tool's contract, and the one
        // an agent typing `Alpha|beta` expects.
        XCTAssertEqual(try search("^let \\w+ = 2$", { $0.isRegex = true }).matches.map(\.line), [2])
        XCTAssertEqual(try search("^LET", { $0.isRegex = true }).matches.count, 2)
        XCTAssertThrowsError(try search("(", { $0.isRegex = true })) { error in
            guard case ProjectTextSearch.Failure.invalidRegex = error else { return XCTFail("\(error)") }
        }
    }

    func testTheExtensionFilterIsCaseInsensitiveAndDotTolerant() throws {
        XCTAssertEqual(try search("alpha", { $0.fileExtension = "TS" }).matches.map(\.relativePath), ["src/b.ts"])
        XCTAssertEqual(try search("alpha", { $0.fileExtension = ".md" }).matches.map(\.relativePath), ["README.md"])
    }

    func testTheLimitStopsTheSearchAndSaysSo() throws {
        let results = try search("a", { $0.limit = 2 })
        XCTAssertEqual(results.matches.count, 2)
        XCTAssertTrue(results.truncated)
    }

    func testAnOpenDirtyBufferBeatsDisk() throws {
        // What the user sees, not what was last saved — the same rule the agent's tool always had.
        let results = try search("unsaved", live: ["a.swift": "unsaved edit\n"])
        XCTAssertEqual(results.matches.map { "\($0.relativePath):\($0.line)" }, ["src/a.swift:1"])
        XCTAssertTrue(try search("gamma", live: ["a.swift": "unsaved edit\n"]).matches.isEmpty)
    }
}
