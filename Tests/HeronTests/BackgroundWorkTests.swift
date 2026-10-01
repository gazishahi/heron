import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, step 5 (D7): what Heron's background work costs.
final class CheckpointCostTests: XCTestCase {
    /// A repository of `files` small files in 100 directories, committed.
    static func largeRepository(files: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heron-repo-\(UUID().uuidString)").resolvingSymlinksInPath()
        for directory in 0..<100 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("d\(directory)"), withIntermediateDirectories: true)
        }
        for file in 0..<files {
            try "file \(file)\n".write(to: root.appendingPathComponent("d\(file % 100)/f\(file).txt"), atomically: false, encoding: .utf8)
        }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["add", "."], ["commit", "-q", "-m", "base"]] {
            XCTAssertTrue(GitPaths.runGit(args, cwd: root.path).success, args.joined(separator: " "))
        }
        return root
    }

    /// Three checkpoints of three changed files each: their median time and most processes. The
    /// baseline status (taken when the batch paused for approval) isn't counted.
    private func checkpoints(in root: URL) throws -> (median: TimeInterval, processes: Int) {
        var samples: [TimeInterval] = []
        var processes: [Int] = []
        for round in 0..<3 {
            let baseline = GitPaths.dirtyPaths(cwd: root.path)
            for file in [2, 3, 4] {
                try "changed \(round)\n".write(to: root.appendingPathComponent("d\(file)/f\(file).txt"), atomically: false, encoding: .utf8)
            }
            let before = GitPaths.metrics.processes
            let start = Date()
            let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: baseline, knownChanged: ["d2/f2.txt"], message: "checkpoint \(round)")
            samples.append(Date().timeIntervalSince(start))
            processes.append(GitPaths.metrics.processes - before)
            guard case .committed(_, let paths)? = outcome else { XCTFail("\(String(describing: outcome))"); break }
            XCTAssertEqual(paths.sorted(), ["d2/f2.txt", "d3/f3.txt", "d4/f4.txt"])
            XCTAssertEqual(GitPaths.runGit(["show", "--name-only", "--format=", "HEAD"], cwd: root.path).output.split(separator: "\n").sorted(), ["d2/f2.txt", "d3/f3.txt", "d4/f4.txt"])
        }
        return (samples.sorted()[samples.count / 2], processes.max() ?? 0)
    }

    /// The usual case, nothing of the user's staged: within the budget, and the real index left
    /// reading the checkpoint as committed.
    func testACheckpointInALargeRepository() throws {
        let root = try Self.largeRepository(files: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let (median, processes) = try checkpoints(in: root)
        print("HERON checkpoint: 20,000 files, \(String(format: "%.0f", median * 1000)) ms median, \(processes) git processes")
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: root.path).output, "", "nothing left modified or staged")
        XCTAssertLessThanOrEqual(median, 0.250)
        XCTAssertLessThanOrEqual(processes, 5)
    }

    /// With the user's own change staged: it stays staged and out of the checkpoint.
    func testTheUsersStagedChangeStaysTheirs() throws {
        let root = try Self.largeRepository(files: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        try "mine\n".write(to: root.appendingPathComponent("d1/f1.txt"), atomically: false, encoding: .utf8)
        XCTAssertTrue(GitPaths.runGit(["add", "d1/f1.txt"], cwd: root.path).success)
        let (_, processes) = try checkpoints(in: root)
        XCTAssertEqual(GitPaths.runGit(["diff", "--cached", "--name-only"], cwd: root.path).output, "d1/f1.txt")
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: root.path).output, "M  d1/f1.txt", "nothing else left modified")
        XCTAssertLessThanOrEqual(processes, 7)
    }

    func testStatusIsReadInOneProcess() {
        let output = ["# branch.oid 779f3530fee286124e742649f5cecc22561d46bb", "# branch.head main",
                      "1 .M N... 100644 100644 100644 aaaa aaaa src/a b.swift",
                      "2 R. N... 100644 100644 100644 bbbb bbbb R100 new.swift", "old.swift",
                      "u UU N... 100644 100644 100644 100644 cccc dddd eeee both.swift",
                      "? café.txt", "! ignored.o"].joined(separator: "\0") + "\0"
        let status = GitPaths.parseStatus(output)
        XCTAssertEqual(status.head, "779f3530fee286124e742649f5cecc22561d46bb")
        XCTAssertEqual(status.dirty, ["src/a b.swift", "new.swift", "both.swift", "café.txt"])
        XCTAssertTrue(status.hasStaged)
        XCTAssertFalse(GitPaths.parseStatus("# branch.oid (initial)\0? a\0").hasStaged)
        XCTAssertNil(GitPaths.parseStatus("# branch.oid (initial)\0").head)
        XCTAssertEqual(AgentRunner.addedPaths("add 'a b'\nremove 'c'", asked: ["a b", "c"]), ["a b", "c"])
        XCTAssertNil(AgentRunner.addedPaths("warning: in the working copy of 'a', LF will be replaced", asked: ["a"]))
        XCTAssertEqual(AgentRunner.addedPaths("", asked: ["a"]), [])
    }

    /// A file the agent changes in place, to the same size, in the second the previous
    /// checkpoint wrote the index: the checkpoint copied the index to a file with a new date,
    /// git took the file's matching stat data as unchanged, and the change was left out
    /// ("nothing to commit"). Seen as this suite's intermittent failure; here it's timed.
    func testAChangeInTheSecondTheIndexWasWrittenIsCheckpointed() throws {
        let root = try Self.largeRepository(files: 100)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("d2/f2.txt")
        func waitForTheNextSecond() { Thread.sleep(forTimeInterval: 1.05 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) }
        waitForTheNextSecond()
        try "changed 0\n".write(to: file, atomically: false, encoding: .utf8)
        guard case .committed? = AgentRunner.stageAndCommit(root: root.path, baseline: [], knownChanged: ["d2/f2.txt"], message: "first") else { return XCTFail("first checkpoint") }
        try "changed 1\n".write(to: file, atomically: false, encoding: .utf8)  // same second, same size, same inode
        waitForTheNextSecond()
        let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: [], knownChanged: ["d2/f2.txt"], message: "second")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(paths, ["d2/f2.txt"])
        XCTAssertEqual(GitPaths.runGit(["show", "HEAD:d2/f2.txt"], cwd: root.path).output, "changed 1")
    }
}

/// No git on the main thread during a turn: an edit applied, a checkpoint made (D7).
@MainActor
final class MainThreadGitTests: XCTestCase {
    func testATurnWithACheckpointRunsNoGitOnTheMainThread() throws {
        let project = try CheckpointCostTests.largeRepository(files: 2_000)
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            switch index {
            case 0: return .tools([(name: "edit_file", input: ##"{"path": "d2/f2.txt", "old_string": "file 2", "new_string": "file two"}"##)])
            case 1: return .tools([(name: "edit_file", input: ##"{"path": "d3/f3.txt", "old_string": "file 3", "new_string": "file three"}"##)])
            default: return .text("Done.")
            }
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .build, autonomy: .full))
        defer { heron.cleanUp() }
        // The test's own git calls, off the main thread so only Heron's count there.
        func commits() -> String {
            var output = ""
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { output = GitPaths.runGit(["rev-list", "--count", "HEAD"], cwd: project.path).output; done.signal() }
            done.wait()
            return output
        }
        let before = GitPaths.metrics
        XCTAssertEqual(heron.send("Rename two."), .finishedTurn)
        // The checkpoints are written in the background; wait for them.
        let deadline = Date().addingTimeInterval(10)
        while commits() != "3", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let after = GitPaths.metrics
        XCTAssertEqual(commits(), "3", "two checkpoints")
        let spent = (after.mainThreadTime - before.mainThreadTime) * 1000
        print("HERON main-thread git: \(String(format: "%.1f", spent)) ms, \(after.processes - before.processes) processes in all; on the main thread: \(after.mainThreadCommands.dropFirst(before.mainThreadCommands.count))")
        XCTAssertEqual(spent, 0, accuracy: 0.001)
    }
}

/// Ten visited tracks hold three transcripts, not ten (D7).
@MainActor
final class RunnerResidencyTests: XCTestCase {
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func testTenVisitedTracksHoldThreeTranscripts() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("heron-residency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let store = AgentSessionStore(stateDirectory: state)
        let keys = (0..<10).map { "track-\($0)" }
        for key in keys {
            for turn in 0..<100 {
                store.appendTurn(AgentTurn(role: .user, content: [.text("Question \(turn) about the store and its cache.")]), trackKey: key, providerId: "anthropic", modelId: "claude-sonnet-5")
                store.appendTurn(AgentTurn(role: .assistant, content: [.text(String(repeating: "An answer about the cache. ", count: 40))]), trackKey: key, providerId: "anthropic", modelId: "claude-sonnet-5")
            }
        }
        let root = state
        let manager = AgentRunnerManager(
            sessionStore: store, projectPath: state.path,
            bridgeProvider: { _ in WorkspaceBridge(liveBufferProvider: { _ in nil }, applyEditIntoOpenTab: { _, _ in false }, onRevealFileRequested: { _ in },
                                                   runShellCommand: { _, _, completion in completion("") }, interruptShellCommand: {}) },
            rootProvider: { _ in root }, modeProvider: { _ in AgentMode(scope: .ask, autonomy: .manual) },
            modelSelectionProvider: { _ in ("anthropic", "claude-sonnet-5", nil) }
        )
        let start = Self.footprintMB()
        for key in keys.prefix(3) { _ = manager.runner(forTrackKey: key) }
        let threeVisited = Self.footprintMB() - start
        for key in keys.dropFirst(3) { _ = manager.runner(forTrackKey: key) }
        let tenVisited = Self.footprintMB() - start
        let held = keys.compactMap { manager.existingRunner(forTrackKey: $0) as? AgentRunner }
        let perTrack = held.last?.entries.count ?? 0
        XCTAssertGreaterThanOrEqual(perTrack, 200)
        XCTAssertEqual(held.filter { !$0.entries.isEmpty }.count, AgentRunnerManager.residentTranscripts)
        XCTAssertEqual(held.map(\.entries.count).reduce(0, +), perTrack * AgentRunnerManager.residentTranscripts)
        print("HERON residency: 10 tracks of 200 turns visited: +\(String(format: "%.1f", tenVisited)) MB, after 3: +\(String(format: "%.1f", threeVisited)) MB")
        XCTAssertLessThanOrEqual(tenVisited, threeVisited + 10, "three transcripts' worth, plus 10 MB")
        // A visit brings one back, whole.
        let first = try XCTUnwrap(manager.runner(forTrackKey: keys[0]) as? AgentRunner)
        XCTAssertEqual(first.entries.count, perTrack)
        XCTAssertFalse(first.isTranscriptDropped)
    }
}

/// `list_files` and `search_files` reuse the last walk while it holds (D7).
final class ProjectScanCacheTests: XCTestCase {
    func testTheWalkIsReusedUntilADirectoryChanges() throws {
        let root = try CheckpointCostTests.largeRepository(files: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }
        func timed(_ body: () -> Void) -> Double { let start = Date(); body(); return Date().timeIntervalSince(start) * 1000 }
        var count = 0
        let first = timed { count = ProjectFileAccess.scan(root: root).count }
        let again = timed { XCTAssertEqual(ProjectFileAccess.scan(root: root).count, count) }
        // Content changes don't change the list; an added, removed or renamed file does.
        try "edited".write(to: root.appendingPathComponent("d5/f5.txt"), atomically: false, encoding: .utf8)
        XCTAssertEqual(ProjectFileAccess.scan(root: root).count, count)
        try "new".write(to: root.appendingPathComponent("d7/new.txt"), atomically: false, encoding: .utf8)
        XCTAssertTrue(ProjectFileAccess.scan(root: root).contains { $0.relativePath == "d7/new.txt" })
        try FileManager.default.moveItem(at: root.appendingPathComponent("d8/f8.txt"), to: root.appendingPathComponent("d8/moved.txt"))
        let after = ProjectFileAccess.scan(root: root).map(\.relativePath)
        XCTAssertTrue(after.contains("d8/moved.txt"))
        XCTAssertFalse(after.contains("d8/f8.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d9/deeper"), withIntermediateDirectories: true)
        try "deep".write(to: root.appendingPathComponent("d9/deeper/x.txt"), atomically: false, encoding: .utf8)
        XCTAssertTrue(ProjectFileAccess.scan(root: root).contains { $0.relativePath == "d9/deeper/x.txt" })
        try "deeper".write(to: root.appendingPathComponent("d9/deeper/y.txt"), atomically: false, encoding: .utf8)
        XCTAssertTrue(ProjectFileAccess.scan(root: root).contains { $0.relativePath == "d9/deeper/y.txt" }, "a new directory is watched too")
        print("HERON scan: 20,000 files, first walk \(String(format: "%.0f", first)) ms, reused \(String(format: "%.1f", again)) ms")
        XCTAssertLessThan(again, first / 5)
    }
}

/// Fewer, smaller writes (D7): the index and usage a moment later; checkpoints per track.
final class StoreWriteTests: XCTestCase {
    func testABurstOfUsageIsWrittenOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-burst-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStore(storeURL: url)
        for _ in 0..<50 {
            store.record(projectPath: "/p", trackKey: "", providerId: "anthropic", modelId: "claude-sonnet-5", usage: TokenUsage(inputTokens: 10, outputTokens: 5, cachedInputTokens: nil))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing written yet")
        JSONStore.flushPendingWrites()
        XCTAssertEqual(UsageStore(storeURL: url).records.first?.totals.requestCount, 50)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("\n  "), "compact")
    }

    func testCheckpointsAreKeptPerTrackAndTheOldLedgerIsSplit() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("heron-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        func checkpoint(_ track: String) -> Checkpoint {
            Checkpoint(trackKey: track, agentSessionId: UUID(), declaredIntent: "work on \(track)", changedFilePaths: ["a.swift"], commandsRun: [],
                       provenance: AgentProvenance(providerId: "anthropic", modelId: "claude-sonnet-5", instructionSourceSummary: ""), gitCommitSHA: "abc")
        }
        // The one-file ledger of before, with an index beside it (a store that has run before).
        let think = state.appendingPathComponent("think")
        XCTAssertTrue(JSONStore.write([checkpoint("feat/a"), checkpoint("feat/b"), checkpoint("feat/a")], to: think.appendingPathComponent("checkpoints.json")))
        XCTAssertTrue(JSONStore.write([String](), to: think.appendingPathComponent("index.json")))
        let store = AgentSessionStore(stateDirectory: state)
        XCTAssertEqual(store.checkpoints(forTrackKey: "feat/a").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: think.appendingPathComponent("checkpoints.json").path), "split, then removed")
        let files = try FileManager.default.contentsOfDirectory(atPath: think.appendingPathComponent("checkpoints").path)
        XCTAssertEqual(files.count, 2)
        // A new checkpoint writes only its own track's file.
        let other = think.appendingPathComponent("checkpoints").appendingPathComponent(files.sorted().first { !$0.contains("b") } ?? files[0])
        let before = try Data(contentsOf: other)
        store.appendCheckpoint(checkpoint("feat/b"))
        XCTAssertEqual(try Data(contentsOf: other), before)
        XCTAssertEqual(AgentSessionStore(stateDirectory: state).checkpoints(forTrackKey: "feat/b").count, 2, "reloads")
        store.removeSession(forTrackKey: "feat/b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: think.appendingPathComponent("checkpoints").path).count, 1)
    }
}

/// 2026-09-30 audit, H4: with git's index lock held, the checkpoint reported success while the
/// real index still staged the old contents, so the person's next commit reverted it.
final class CheckpointIndexLockTests: XCTestCase {
    private func repo() throws -> URL {
        let root = try CheckpointCostTests.largeRepository(files: 50)
        try "agent\n".write(to: root.appendingPathComponent("d2/f2.txt"), atomically: false, encoding: .utf8)
        return root
    }

    private func holdLock(_ root: URL, for seconds: TimeInterval) {
        let lock = root.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { try? FileManager.default.removeItem(at: lock) }
    }

    func testALockHeldBrieflyStillLeavesTheIndexRight() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        holdLock(root, for: 1.5)
        let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: [], knownChanged: ["d2/f2.txt"], message: "checkpoint")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(paths, ["d2/f2.txt"])
        XCTAssertEqual(GitPaths.runGit(["status", "--porcelain"], cwd: root.path).output, "", "the index reads the checkpoint as committed")
    }

    func testALockHeldThroughoutIsReportedNotHidden() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        holdLock(root, for: 15)
        let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: [], knownChanged: ["d2/f2.txt"], message: "checkpoint")
        guard case .committedIndexStale(_, let paths)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(paths, ["d2/f2.txt"])
        XCTAssertTrue(outcome?.staleIndexWarning?.contains("git reset -q HEAD -- 'd2/f2.txt'") == true)
    }
}

/// 2026-09-30 audit, GIT-5, R3, GIT-7: conversations and checkpoint records survive a crash in
/// the index's delay, a corrupt index, and an old ledger coming back.
final class SessionIndexDurabilityTests: XCTestCase {
    private func state() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("heron-durable-\(UUID().uuidString)")
    }

    private func checkpoint(_ track: String, _ intent: String) -> Checkpoint {
        Checkpoint(trackKey: track, agentSessionId: UUID(), declaredIntent: intent, changedFilePaths: ["a.swift"], commandsRun: [],
                   provenance: AgentProvenance(providerId: "anthropic", modelId: "claude-sonnet-5", instructionSourceSummary: ""), gitCommitSHA: "abc")
    }

    func testANewTracksEntryIsOnDiskAtOnce() throws {
        let dir = state()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentSessionStore(stateDirectory: dir)
        store.appendTurn(AgentTurn(role: .user, content: [.text("first")]), trackKey: "a", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendTurn(AgentTurn(role: .user, content: [.text("second track")]), trackKey: "feat/b", providerId: "anthropic", modelId: "claude-sonnet-5")
        // No flush: what a crash right now would leave.
        let onDisk = try String(contentsOf: dir.appendingPathComponent("think/index.json"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("feat\\/b") || onDisk.contains("feat/b"), onDisk)
    }

    func testACorruptIndexLosesNothing() throws {
        let dir = state()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentSessionStore(stateDirectory: dir)
        store.appendTurn(AgentTurn(role: .user, content: [.text("keep me")]), trackKey: "a", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendCheckpoint(checkpoint("a", "one"))
        store.appendCheckpoint(checkpoint("a", "two"))
        JSONStore.flushPendingWrites()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("think/index.json"))

        let reopened = AgentSessionStore(stateDirectory: dir)
        XCTAssertEqual(reopened.session(forTrackKey: "a")?.turns.count, 1, "found from its file")
        XCTAssertEqual(reopened.checkpoints(forTrackKey: "a").count, 2)
        reopened.appendCheckpoint(checkpoint("a", "three"))
        XCTAssertEqual(AgentSessionStore(stateDirectory: dir).checkpoints(forTrackKey: "a").map(\.declaredIntent), ["one", "two", "three"])
    }

    func testAnOldLedgerIsMergedNotWrittenOver() throws {
        let dir = state()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentSessionStore(stateDirectory: dir)
        store.appendTurn(AgentTurn(role: .user, content: [.text("x")]), trackKey: "a", providerId: "anthropic", modelId: "claude-sonnet-5")
        store.appendCheckpoint(checkpoint("a", "made since"))
        JSONStore.flushPendingWrites()
        XCTAssertTrue(JSONStore.write([checkpoint("a", "from the old ledger")], to: dir.appendingPathComponent("think/checkpoints.json")))
        let reopened = AgentSessionStore(stateDirectory: dir)
        XCTAssertEqual(Set(reopened.checkpoints(forTrackKey: "a").map(\.declaredIntent)), ["made since", "from the old ledger"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("think/checkpoints.json").path))
    }
}
