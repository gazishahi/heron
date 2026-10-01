import XCTest
@testable import Heron

final class TrackOverlapTests: XCTestCase {

    func testOnlySharedPathsAreReported() {
        let siblings = TrackOverlap.siblings(
            of: "feature-a",
            changedPathsByBranch: [
                "feature-a": ["src/App.swift", "src/Util.swift"],
                "feature-b": ["src/Util.swift", "README.md"],
            ],
            intentsByBranch: ["feature-b": "tidy the utils"]
        )
        XCTAssertEqual(siblings.count, 1)
        // The intersection, not either track's full set — a banner listing files the other
        // track touched but this one didn't would be noise pretending to be a warning.
        XCTAssertEqual(siblings.first?.sharedPaths, ["src/Util.swift"])
        XCTAssertEqual(siblings.first?.intent, "tidy the utils")
    }

    func testSiblingFiltering() {
        // Tracks with no overlap are dropped, the track never overlaps itself, and a track that
        // changed nothing has no overlap with anyone.
        let cases: [(name: String, of: String, paths: [String: Set<String>])] = [
            ("no shared paths", "feature-a", ["feature-a": ["src/App.swift"], "feature-b": ["docs/guide.md"]]),
            ("only itself", "feature-a", ["feature-a": ["src/App.swift"]]),
            ("changed nothing", "fresh", ["fresh": [], "busy": ["a.swift"]]),
        ]
        for row in cases {
            let siblings = TrackOverlap.siblings(of: row.of, changedPathsByBranch: row.paths, intentsByBranch: [:])
            XCTAssertTrue(siblings.isEmpty, "\(row.name): \(siblings.map(\.branchName))")
        }
    }

    func testSiblingOrdering() {
        // The worst overlap comes first. Dictionary iteration order isn't stable between runs;
        // without a tiebreak the banner would reshuffle on every refresh for no visible reason.
        let siblings = TrackOverlap.siblings(
            of: "mine",
            changedPathsByBranch: [
                "mine": ["a.swift", "b.swift", "c.swift"],
                "light": ["c.swift"],
                "heavy": ["a.swift", "b.swift"],
            ],
            intentsByBranch: [:]
        )
        XCTAssertEqual(siblings.map(\.branchName), ["heavy", "light"])

        let equal: [String: Set<String>] = [
            "mine": ["a.swift"],
            "zebra": ["a.swift"],
            "alpha": ["a.swift"],
        ]
        for _ in 0..<5 {
            let tied = TrackOverlap.siblings(of: "mine", changedPathsByBranch: equal, intentsByBranch: [:])
            XCTAssertEqual(tied.map(\.branchName), ["alpha", "zebra"])
        }
    }

    // MARK: - Summary

    func testHeadline() {
        // Names the other track by intent, falls back to the branch name without one, counts
        // additional tracks, and is absent when there are no siblings — no banner.
        let cases: [(name: String, siblings: [TrackOverlap.Sibling], headline: String?)] = [
            ("names the intent",
             [.init(branchName: "feature-b", intent: "tidy the utils", sharedPaths: ["src/Util.swift"])],
             "Also being changed by \u{201C}tidy the utils\u{201D}"),
            ("falls back to the branch name",
             [.init(branchName: "feature-b", intent: "", sharedPaths: ["a.swift", "b.swift"])],
             "Also being changed by \u{201C}feature-b\u{201D}"),
            ("counts additional tracks",
             [.init(branchName: "b", intent: "", sharedPaths: ["a.swift"]),
              .init(branchName: "c", intent: "", sharedPaths: ["a.swift"]),
              .init(branchName: "d", intent: "", sharedPaths: ["a.swift"])],
             "Also being changed by \u{201C}b\u{201D} and 2 other tracks"),
            ("no siblings, no banner", [], nil),
        ]
        for row in cases {
            XCTAssertEqual(TrackOverlap.headline(for: row.siblings), row.headline, row.name)
        }
    }

    func testSharedPathsSummary() {
        // The banner has the width; "3 files" without naming them is the count without the
        // answer to the question it provokes. Paths are deduplicated across tracks, and a large
        // overlap is capped rather than wrapping.
        let named = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: ["src/a.swift", "src/b.swift"])
        ])
        XCTAssertTrue(named.contains("src/a.swift"), named)
        XCTAssertTrue(named.contains("src/b.swift"), named)

        let deduplicated = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: ["a.swift"]),
            .init(branchName: "c", intent: "", sharedPaths: ["a.swift", "b.swift"]),
        ])
        XCTAssertEqual(deduplicated, "a.swift  \u{00B7}  b.swift")

        let many = (1...9).map { "file\($0).swift" }
        let capped = TrackOverlap.sharedPathsSummary(for: [
            .init(branchName: "b", intent: "", sharedPaths: many)
        ])
        XCTAssertTrue(capped.contains("+5 more"), capped)
        XCTAssertFalse(capped.contains("file9.swift"), capped)
    }

    // MARK: - Against a real repository

    func testChangedPathsUsesTheMergeBaseNotTheBaseTip() throws {
        // The three-dot case: work landing on the base *after* a track branched must not be
        // reported as that track's own change, or every stacked track would look like it
        // overlaps everything its parent has done since.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        defer { try? FileManager.default.removeItem(at: dir) }

        func git(_ args: [String]) { XCTAssertTrue(GitPaths.runGit(args, cwd: path).success, args.joined(separator: " ")) }
        func write(_ name: String, _ text: String) { try? text.write(toFile: path + "/" + name, atomically: true, encoding: .utf8) }

        git(["init", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "T"])
        write("base.txt", "base\n")
        git(["add", "."]); git(["commit", "-m", "base"])

        git(["checkout", "-b", "feature"])
        write("mine.txt", "mine\n")
        git(["add", "."]); git(["commit", "-m", "feature work"])

        // Meanwhile, main moves on independently.
        git(["checkout", "main"])
        write("theirs.txt", "theirs\n")
        git(["add", "."]); git(["commit", "-m", "main work"])

        let changed = TrackOverlap.changedPaths(branch: "feature", baseRef: "main", cwd: path)
        XCTAssertEqual(changed, ["mine.txt"])
    }
}
