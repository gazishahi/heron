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

    func testARenameReportsBothPathsAndNothingElse() throws {
        git(["mv", "src/a.txt", "src/renamed.txt"])
        let paths = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        // Under -z a rename is two NUL-separated fields: the destination, then the source. The
        // source is dirty too (GIT-4); the two fields mustn't run into one another or the next
        // entry.
        XCTAssertEqual(paths, ["src/renamed.txt", "src/a.txt"])
    }

    /// GIT-4: a `git mv` in a batch is a move in the checkpoint, and leaves nothing staged.
    func testAStagedRenameIsCheckpointedAsAMove() throws {
        let baseline = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        git(["mv", "src/a.txt", "src/moved.txt"])
        XCTAssertEqual(GitPaths.dirtyPaths(cwd: root.path), ["src/moved.txt", "src/a.txt"], "the source too")
        guard case .committed? = AgentRunner.stageAndCommit(root: root.path, baseline: baseline, knownChanged: [], message: "move") else {
            return XCTFail("not committed")
        }
        let tree = GitPaths.runGit(["ls-tree", "-r", "--name-only", "HEAD"], cwd: root.path).output
        XCTAssertEqual(tree.split(separator: "\n"), ["src/b.txt", "src/moved.txt"], "a move, not a copy")
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: root.path).output, "", "nothing left staged")
    }

    /// GIT-6: changes inside a submodule aren't passed off as a checkpoint with no changes.
    func testChangesInsideASubmoduleAreNamed() throws {
        let inner = FileManager.default.temporaryDirectory.appendingPathComponent("inner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inner) }
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
            XCTAssertTrue(GitPaths.runGit(args, cwd: inner.path).success)
        }
        try "inner\n".write(to: inner.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitPaths.runGit(["add", "."], cwd: inner.path).success)
        XCTAssertTrue(GitPaths.runGit(["commit", "-m", "inner"], cwd: inner.path).success)
        git(["-c", "protocol.file.allow=always", "submodule", "add", inner.path, "vendor"])
        git(["commit", "-m", "submodule"])

        let baseline = try XCTUnwrap(GitPaths.dirtyPaths(cwd: root.path))
        try "edited\n".write(to: root.appendingPathComponent("vendor/lib.txt"), atomically: true, encoding: .utf8)
        let (outcome, submodules) = AgentRunner.stageAndCommitReporting(root: root.path, baseline: baseline, knownChanged: [], message: "edit")
        guard case .nothingToCommit? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(submodules, ["vendor"])
        XCTAssertNotNil(AgentRunner.uncommittedSubmoduleNote(submodules))
        XCTAssertNil(AgentRunner.uncommittedSubmoduleNote([]))
    }
}
