import XCTest
@testable import Heron

final class FileMentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mentions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data("export const a = 1\n".utf8).write(to: root.appendingPathComponent("src/greeter.ts"))
        try Data("readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("deep\n".utf8).write(to: root.appendingPathComponent("src/deep/nested.swift"))
        try Data("vendored\n".utf8).write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Token scanning

    func testTokenScanning() {
        // An email's `@` has a non-boundary character before it — treating it as a file reference
        // would make every address in a message a broken mention. Punctuation after a mention
        // stays punctuation, a bare `@` is not a mention, and "with @." in prose is punctuation
        // too (an early version styled it as a file reference, which made the highlighting look
        // broken) — but a real dotfile still counts.
        let cases: [(text: String, tokens: [String])] = [
            ("look at @src/greeter.ts and mail me@example.com", ["src/greeter.ts"]),
            ("compare @a.swift, @b.swift; then stop", ["a.swift", "b.swift"]),
            ("check @README.md?", ["README.md"]),
            ("(see @src/greeter.ts)", ["src/greeter.ts"]),
            ("what does @ mean", []),
            ("@", []),
            ("referenced with @.", []),
            ("a @- b", []),
            ("see @.gitignore", [".gitignore"]),
        ]
        for row in cases {
            XCTAssertEqual(FileMentionResolver.mentionTokens(in: row.text), row.tokens, row.text)
            XCTAssertEqual(FileMentionResolver.tokenRanges(in: row.text).count, row.tokens.count, "highlight ranges for: \(row.text)")
        }
    }

    // MARK: - Resolution

    func testResolution() {
        // Real paths resolve; a typo is reported, not dropped — silently ignoring it is how an
        // agent ends up confidently answering about a file nobody meant. Directories resolve and
        // are labelled as such, and a path mentioned twice appears once.
        let typo = FileMentionResolver.resolve(
            text: "explain @src/greeter.ts and @src/nope.ts", projectRoot: root
        )
        XCTAssertEqual(typo.mentions.map(\.relativePath), ["src/greeter.ts"])
        XCTAssertEqual(typo.unresolved, ["src/nope.ts"])

        let directory = FileMentionResolver.resolve(text: "look through @src/deep/", projectRoot: root)
        XCTAssertEqual(directory.mentions.first?.relativePath, "src/deep")
        XCTAssertEqual(directory.mentions.first?.isDirectory, true)

        let repeated = FileMentionResolver.resolve(text: "@README.md is like @README.md", projectRoot: root)
        XCTAssertEqual(repeated.mentions.count, 1)
    }

    func testEscapingTheProjectRootIsRefused() {
        let result = FileMentionResolver.resolve(
            text: "read @../../etc/passwd and @/etc/hosts", projectRoot: root
        )
        // Same containment rule the tools apply — a mention must not become a path traversal.
        XCTAssertTrue(result.mentions.isEmpty, "resolved: \(result.mentions)")
        XCTAssertEqual(result.unresolved.count, 2)
    }

    // MARK: - What actually gets sent

    func testContextNote() throws {
        // The whole design decision, pinned: the note carries paths, not contents — inlining
        // content would persist a copy in the session file and re-send it on every later turn for
        // the rest of the track's life. Unresolved mentions tell the agent to ask rather than
        // guess, and no mentions means no note at all.
        let result = FileMentionResolver.resolve(text: "summarize @src/greeter.ts", projectRoot: root)
        let note = try XCTUnwrap(FileMentionResolver.contextNote(mentions: result.mentions, unresolved: []))
        XCTAssertTrue(note.contains("src/greeter.ts"), note)
        XCTAssertFalse(note.contains("export const a = 1"), note)
        XCTAssertTrue(note.lowercased().contains("read_file"), "the agent has to be told how to get the contents")

        let unresolved = try XCTUnwrap(FileMentionResolver.contextNote(mentions: [], unresolved: ["src/nope.ts"]))
        XCTAssertTrue(unresolved.contains("src/nope.ts"))
        XCTAssertTrue(unresolved.lowercased().contains("ask the user"), unresolved)

        XCTAssertNil(FileMentionResolver.contextNote(mentions: [], unresolved: []))
    }

    // MARK: - Completion index

    func testIndexSkipsVendoredDirectoriesAndFuzzyMatches() {
        let index = ProjectFileIndex()
        let done = expectation(description: "indexed")
        index.refresh(root: root) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(index.relativePaths.contains("src/greeter.ts"))
        // node_modules is noise in a completion list, and matches what the file tree hides.
        XCTAssertFalse(index.relativePaths.contains { $0.hasPrefix("node_modules") }, "\(index.relativePaths)")

        // Same scorer as Quick Open, so initials work here too.
        XCTAssertEqual(index.matches(for: "greeter").first, "src/greeter.ts")
        XCTAssertTrue(index.matches(for: "sdn").contains("src/deep/nested.swift"))
    }
}

/// The crash this feature first shipped with is gone by construction rather than by guard:
/// completion no longer calls `NSTextView.complete(_:)` at all, so there is no
/// insert-during-textDidChange path to recurse through. `MentionCompletionPopup` only displays;
/// text changes exclusively when a row is accepted. See that file's note for the full account.

/// Covers the highlighting/click surface: which spans of text get styled as mentions, and the
/// empty-query behaviour behind a bare `@`.
final class MentionPresentationTests: XCTestCase {

    private func highlighted(_ text: String) -> [String] {
        let ns = text as NSString
        return FileMentionResolver.tokenRanges(in: text).map { ns.substring(with: $0) }
    }

    func testHighlightRangesAgreeWithWhatGetsSent() {
        // Two code paths read the same text — one decides what's *shown* as a mention, the other
        // what's *sent*. If they disagree, the user sees a styled reference the agent was never
        // told about (or the reverse). Punctuation-only tokens are where they first diverged.
        let texts = [
            "compare @a.swift, @b/c.swift; ignore me@example.com and a bare @",
            "check @. and @src/a.swift plus @-",
        ]
        for text in texts {
            XCTAssertEqual(
                highlighted(text).map { String($0.dropFirst()) },
                FileMentionResolver.mentionTokens(in: text),
                text
            )
        }
    }

    func testBareAtOffersShallowPathsFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bare-at-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("TOP.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a/mid.swift"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a/b/c/deep.swift"))

        let index = ProjectFileIndex()
        let done = expectation(description: "indexed")
        index.refresh(root: root) { done.fulfill() }
        wait(for: [done], timeout: 5)

        // Filesystem enumeration order would look arbitrary; a bare `@` should open on the
        // project's top level.
        XCTAssertEqual(index.matches(for: "").first, "TOP.md")
        XCTAssertEqual(index.matches(for: "").last, "a/b/c/deep.swift")
    }
}
