import XCTest
@testable import Heron

/// `dirtyPaths` decides which files a checkpoint stages. A path it gets wrong is a checkpoint
/// that fails — and before failures were reported honestly, one that failed *silently*.
final class DirtyPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dirty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        git(["init", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "one\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-m", "base"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func git(_ args: [String]) {
        XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success, args.joined(separator: " "))
    }

    func testAWorktreeModifiedFirstEntryKeepsItsFullPath() throws {
        // The regression this file exists for. `git status --porcelain` reports a
        // worktree-modified file as " M path" — leading space significant. Running it through
        // the trimming `runGit` ate that space, so the 3-character prefix drop returned
        // "rc/a.txt" instead of "src/a.txt": a path git had never heard of, which made every
        // checkpoint fail whenever the first dirty file was merely modified.
        try "changed\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        let paths = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        XCTAssertEqual(paths, ["src/a.txt"])
        // And the point of getting it right: git must actually accept the path.
        XCTAssertTrue(GitPaths.runGit(["add", "--"] + paths.sorted(), cwd: root.path).success)
    }

    func testStatusShapesRoundTrip() throws {
        // A clean tree reports nothing; every porcelain shape — staged, worktree-modified,
        // untracked — reports its full path.
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), [])
        try "changed\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        git(["add", "src/a.txt"])                                    // "M  src/a.txt"
        try "changed\n".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)  // " M src/b.txt"
        try "new\n".write(to: root.appendingPathComponent("src/c.txt"), atomically: true, encoding: .utf8)      // "?? src/c.txt"
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), ["src/a.txt", "src/b.txt", "src/c.txt"])
    }

    func testANonASCIIFilenameSurvives() throws {
        // git quotes such paths without -z, and the quotes then defeated `git add`.
        try "hi\n".write(to: root.appendingPathComponent("café.txt"), atomically: true, encoding: .utf8)
        let paths = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        XCTAssertTrue(paths.contains("café.txt"), "\(paths)")
        XCTAssertTrue(GitPaths.runGit(["add", "--"] + paths.sorted(), cwd: root.path).success)
    }

    /// 2026-09-30 audit, GIT-11: a status git couldn't produce read as a clean tree.
    func testAFailedStatusIsUnknownNotClean() throws {
        let notARepository = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepository) }
        XCTAssertNil(GitPaths.dirtyPaths(cwd: notARepository.path))
        XCTAssertNil(GitPaths.status(cwd: notARepository.path))
    }

    /// 2026-09-30 audit, GIT-3: a new directory was one entry, `newdir/`, and with
    /// `status.showUntrackedFiles=no` new files weren't listed at all.
    func testANewDirectorysFilesAreListedOneByOne() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("newdir/deeper"), withIntermediateDirectories: true)
        try "n".write(to: root.appendingPathComponent("newdir/notes.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("newdir/deeper/x.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), ["newdir/notes.md", "newdir/deeper/x.swift"])
        git(["config", "status.showUntrackedFiles", "no"])
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), ["newdir/notes.md", "newdir/deeper/x.swift"])
    }

    /// Ignored entries only when asked for, and never as dirty.
    func testIgnoredFilesAreListedApartWhenAsked() throws {
        try ".env\nbuild/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        git(["add", ".gitignore"])
        git(["commit", "-qm", "ignore"])
        try "SECRET=1\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), [])
        let status = try XCTUnwrap(GitPaths.status(cwd: root.path, includeIgnored: true))
        XCTAssertEqual(status.dirty, [])
        XCTAssertEqual(status.ignored, [".env", "build/"], "an ignored directory is one entry")
    }

    func testARenameReportsOnlyTheDestination() throws {
        git(["mv", "src/a.txt", "src/renamed.txt"])
        let paths = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        // Under -z a rename is two NUL-separated fields; the source no longer exists, so
        // including it would stage a path git must reject.
        XCTAssertTrue(paths.contains("src/renamed.txt"), "\(paths)")
        XCTAssertFalse(paths.contains("src/a.txt"), "\(paths)")
    }
}
