import XCTest
@testable import Heron

/// Undo is the one feature whose bugs are unrecoverable by definition — if it destroys work, the
/// work is gone. These cover both halves: the ordering/selection logic (pure), and the git
/// sequence itself against a real repository.
final class CheckpointRestoreTests: XCTestCase {

    private func checkpoint(_ intent: String, sha: String?, at offset: TimeInterval) -> Checkpoint {
        var checkpoint = Checkpoint(
            trackKey: "main", agentSessionId: UUID(), declaredIntent: intent,
            changedFilePaths: [], commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""),
            gitCommitSHA: sha
        )
        // createdAt is set at init; re-encode with the offset so ordering is deterministic.
        let json = try! JSONEncoder().encode(checkpoint)
        var object = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["createdAt"] = Date(timeIntervalSinceReferenceDate: offset).timeIntervalSinceReferenceDate
        let patched = try! JSONSerialization.data(withJSONObject: object)
        checkpoint = try! JSONDecoder().decode(Checkpoint.self, from: patched)
        return checkpoint
    }

    // MARK: - What gets reverted, and in what order

    func testSingleScopeRevertsOnlyThatCheckpoint() {
        let first = checkpoint("first", sha: "aaa", at: 100)
        let second = checkpoint("second", sha: "bbb", at: 200)
        let third = checkpoint("third", sha: "ccc", at: 300)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [first, second, third], target: second, scope: .single),
            ["bbb"]
        )
    }

    func testRestoringThroughLatestRevertsNewestFirstByTimeAndOnlyKnownTargets() {
        // Order is the whole correctness question: reversing the oldest first would try to undo
        // a change against a tree that later commits have already moved on from, and conflict
        // for reasons that look like git misbehaving.
        let first = checkpoint("first", sha: "aaa", at: 100)
        let second = checkpoint("second", sha: "bbb", at: 200)
        let third = checkpoint("third", sha: "ccc", at: 300)
        let stranger = checkpoint("stranger", sha: "zzz", at: 150)
        let cases: [(name: String, checkpoints: [Checkpoint], target: Checkpoint, expected: [String])] = [
            ("newest first", [first, second, third], second, ["ccc", "bbb"]),
            // Sorted by time, not by the order the caller happened to hand them over.
            ("out-of-order input", [second, first], first, ["bbb", "aaa"]),
            ("unknown target reverts nothing", [first], stranger, []),
        ]
        for row in cases {
            XCTAssertEqual(
                CheckpointRestore.commitsToRevert(checkpoints: row.checkpoints, target: row.target, scope: .throughLatest),
                row.expected, row.name
            )
        }
    }

    func testCheckpointsWithNoCommitAreSkipped() {
        // A command-only checkpoint has no commit — there's nothing to revert, and including a
        // nil would either crash or revert the wrong thing.
        let first = checkpoint("edit", sha: "aaa", at: 100)
        let second = checkpoint("ran tests", sha: nil, at: 200)
        let third = checkpoint("edit again", sha: "ccc", at: 300)
        XCTAssertEqual(
            CheckpointRestore.commitsToRevert(checkpoints: [first, second, third], target: first, scope: .throughLatest),
            ["ccc", "aaa"]
        )
    }

    func testMessageNamesWhatIsBeingUndone() {
        let target = checkpoint("add the parser", sha: "aaa", at: 100)
        XCTAssertTrue(CheckpointRestore.revertMessage(target: target, scope: .single, count: 1).contains("add the parser"))
        let many = CheckpointRestore.revertMessage(target: target, scope: .throughLatest, count: 3)
        XCTAssertTrue(many.contains("3"), many)
    }

    // MARK: - Against a real repository

    private func makeRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        for args in [["init"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
            XCTAssertTrue(GitPaths.runGit(args, cwd: path).success, "git \(args.joined(separator: " "))")
        }
        return path
    }

    private func commit(_ contents: String, to file: String, in path: String, message: String) -> String {
        try? contents.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        XCTAssertTrue(GitPaths.runGit(["add", "."], cwd: path).success)
        XCTAssertTrue(GitPaths.runGit(["commit", "-m", message], cwd: path).success)
        return GitPaths.runGit(["rev-parse", "HEAD"], cwd: path).output
    }

    func testRevertingRestoresTheContentAndKeepsHistory() throws {
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")

        let outcome = CheckpointRestore.perform(commits: [agentSHA], message: "Undo agent checkpoint", worktreePath: path)
        guard case .reverted(_, let count) = outcome else { return XCTFail("expected revert, got \(outcome)") }
        XCTAssertEqual(count, 1)

        let contents = try String(contentsOfFile: path + "/a.txt", encoding: .utf8)
        XCTAssertEqual(contents, "original\n")
        // Forward motion, not erasure: the agent's commit is still in the log, plus the undo.
        let log = GitPaths.runGit(["log", "--oneline"], cwd: path).output
        XCTAssertTrue(log.contains("agent edit"), log)
        XCTAssertEqual(log.split(separator: "\n").count, 3, log)
    }

    func testUncommittedWorkInOtherFilesSurvives() throws {
        // The reason this is a revert and not `reset --hard`. A user's unsaved-to-git work sits
        // in the tree constantly; an undo that eats it is worse than no undo at all.
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")
        try "my own work in progress\n".write(toFile: path + "/mine.txt", atomically: true, encoding: .utf8)

        _ = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path)

        XCTAssertEqual(try String(contentsOfFile: path + "/mine.txt", encoding: .utf8), "my own work in progress\n")
    }

    func testRevertingSeveralCheckpointsProducesOneCommit() throws {
        let path = try makeRepo()
        _ = commit("v0\n", to: "a.txt", in: path, message: "base")
        let first = commit("v1\n", to: "a.txt", in: path, message: "agent 1")
        let second = commit("v2\n", to: "a.txt", in: path, message: "agent 2")

        let outcome = CheckpointRestore.perform(commits: [second, first], message: "Undo 2 checkpoints", worktreePath: path)
        guard case .reverted(_, let count) = outcome else { return XCTFail("expected revert, got \(outcome)") }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "v0\n")
        // One undo entry, not one per checkpoint — the log should read like the decision, not
        // like the mechanism.
        XCTAssertEqual(GitPaths.runGit(["log", "--oneline"], cwd: path).output.split(separator: "\n").count, 4)
    }

    func testAConflictLeavesTheWorktreeAndUncommittedWorkUntouched() throws {
        // The original conflict test left the worktree clean at the moment of the conflict, so
        // `abandon()`'s `git reset --hard HEAD` looked harmless. With real uncommitted work
        // present, that reset destroyed it — the exact failure this whole file exists to
        // prevent. Found by an audit, not by the suite.
        let path = try makeRepo()
        _ = commit("line\n", to: "a.txt", in: path, message: "base")
        _ = commit("tracked\n", to: "mine.txt", in: path, message: "add mine")
        let agentSHA = commit("agent line\n", to: "a.txt", in: path, message: "agent edit")
        // Someone edited the same line afterwards, so the reversal can't apply cleanly.
        _ = commit("human line\n", to: "a.txt", in: path, message: "human edit")

        // Uncommitted work of both kinds, in files the checkpoint never touched.
        try "my unsaved edit\n".write(toFile: path + "/mine.txt", atomically: true, encoding: .utf8)
        try "brand new\n".write(toFile: path + "/untracked.txt", atomically: true, encoding: .utf8)

        let outcome = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path)
        guard case .conflicted(let paths) = outcome else { return XCTFail("expected conflict, got \(outcome)") }
        XCTAssertEqual(paths, ["a.txt"])

        XCTAssertEqual(try String(contentsOfFile: path + "/mine.txt", encoding: .utf8), "my unsaved edit\n",
                       "a failed undo destroyed the user's uncommitted edit")
        XCTAssertEqual(try String(contentsOfFile: path + "/untracked.txt", encoding: .utf8), "brand new\n")
        // Half-undone with conflict markers in it would be the worst possible outcome — the
        // conflicted file must read exactly as it did before the attempt, no revert is left in
        // progress, and the only thing dirty in the tree is the user's own work.
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "human line\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/.git/REVERT_HEAD"))
        let status = GitPaths.runGit(["status", "--porcelain"], cwd: path).output
        // runGit trims its output, which eats the leading space of a " M" row — so compare
        // (status code, path) rather than raw porcelain lines.
        let rows = Set(status.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(rows, ["M mine.txt", "?? untracked.txt"], status)
    }

    /// 2026-09-30 audit, C2: a failed undo reset the person's staged file to HEAD in the index
    /// and the worktree, and a successful one committed it as the undo.
    func testStagedWorkIsNeverTakenIntoOrWipedByAnUndo() throws {
        let path = try makeRepo()
        _ = commit("line\n", to: "a.txt", in: path, message: "base")
        _ = commit("tracked\n", to: "user.txt", in: path, message: "add user")
        let agentSHA = commit("agent line\n", to: "a.txt", in: path, message: "agent edit")
        try "USER PRECIOUS\n".write(toFile: path + "/user.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(GitPaths.runGit(["add", "user.txt"], cwd: path).success)

        let outcome = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path)
        XCTAssertEqual(outcome, .stagedChanges(paths: ["user.txt"]))
        XCTAssertEqual(try String(contentsOfFile: path + "/user.txt", encoding: .utf8), "USER PRECIOUS\n")
        XCTAssertEqual(GitPaths.runGit(["diff", "--cached", "--name-only"], cwd: path).output, "user.txt", "still staged")
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "agent line\n", "nothing reverted")

        // Unstaged, the undo goes ahead and holds only the checkpoint's file.
        XCTAssertTrue(GitPaths.runGit(["reset", "-q", "user.txt"], cwd: path).success)
        guard case .reverted(let undoSHA, _) = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path) else {
            return XCTFail("expected the undo to go ahead")
        }
        XCTAssertEqual(GitPaths.runGit(["show", "--name-only", "--format=", undoSHA], cwd: path).output, "a.txt")
        XCTAssertEqual(try String(contentsOfFile: path + "/user.txt", encoding: .utf8), "USER PRECIOUS\n")
    }

    /// A failed final commit (a pre-commit hook that refuses) unwinds only the checkpoint's files.
    func testAFailedUndoCommitUnwindsOnlyTheCheckpointsFiles() throws {
        let path = try makeRepo()
        _ = commit("line\n", to: "a.txt", in: path, message: "base")
        _ = commit("tracked\n", to: "mine.txt", in: path, message: "add mine")
        let agentSHA = commit("agent line\n", to: "a.txt", in: path, message: "agent edit")
        try "my unsaved edit\n".write(toFile: path + "/mine.txt", atomically: true, encoding: .utf8)
        let hook = path + "/.git/hooks/pre-commit"
        try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)

        guard case .failed = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path) else {
            return XCTFail("expected the hook to refuse the commit")
        }
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "agent line\n", "the revert was unwound")
        XCTAssertEqual(try String(contentsOfFile: path + "/mine.txt", encoding: .utf8), "my unsaved edit\n")
        XCTAssertEqual(GitPaths.runGit(["diff", "--cached", "--name-only"], cwd: path).output, "")
    }

    func testUndoingAnUndoIsJustAnotherRevert() throws {
        // Falls out of the design, and is worth pinning: reverts are ordinary commits, so the
        // undo of an undo needs no special case anywhere.
        let path = try makeRepo()
        _ = commit("original\n", to: "a.txt", in: path, message: "base")
        let agentSHA = commit("agent wrote this\n", to: "a.txt", in: path, message: "agent edit")

        guard case .reverted(let undoSHA, _) = CheckpointRestore.perform(commits: [agentSHA], message: "Undo", worktreePath: path) else {
            return XCTFail("first revert failed")
        }
        guard case .reverted = CheckpointRestore.perform(commits: [undoSHA], message: "Redo", worktreePath: path) else {
            return XCTFail("second revert failed")
        }
        XCTAssertEqual(try String(contentsOfFile: path + "/a.txt", encoding: .utf8), "agent wrote this\n")
    }

    func testNothingToRevertIsNotAFailure() {
        XCTAssertEqual(CheckpointRestore.perform(commits: [], message: "x", worktreePath: "/tmp"), .nothingToDo)
    }
}
