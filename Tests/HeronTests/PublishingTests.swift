import XCTest
@testable import Heron

/// Review's publishing half, against a real local bare remote.
final class PublishingTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("publish-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    private func git(_ args: [String], in dir: URL) -> String {
        let result = GitPaths.runGit(args, cwd: dir.path)
        XCTAssertTrue(result.success, "git \(args): \(result.output)")
        return result.output
    }

    private func commit(_ file: String, _ text: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        git(["add", file], in: dir)
        git(["commit", "-q", "-m", "\(file): \(text)"], in: dir)
    }

    func testPushStateFetchAndARejectedPush() throws {
        let remote = base.appendingPathComponent("remote.git")
        git(["init", "-q", "--bare", "-b", "main", remote.path], in: base)
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo)
        git(["config", "user.email", "t@t"], in: repo); git(["config", "user.name", "T"], in: repo)
        try commit("a.txt", "one", in: repo)
        git(["remote", "add", "origin", remote.path], in: repo)
        git(["push", "-q", "-u", "origin", "main"], in: repo)
        git(["checkout", "-q", "-b", "feature"], in: repo)
        try commit("b.txt", "two", in: repo)
        try commit("c.txt", "three", in: repo)

        var state = Publishing.state(branch: "feature", baseRef: "main", cwd: repo.path)
        XCTAssertEqual(state.remote?.name, "origin")
        XCTAssertFalse(state.isOnRemote)
        XCTAssertEqual(state.unpushed, 2, "the branch's own commits, not main's")
        XCTAssertTrue(state.baseIsOnRemote)

        let pushed = Publishing.push(branch: "feature", remote: "origin", cwd: repo.path)
        XCTAssertTrue(pushed.succeeded, pushed.message)
        state = Publishing.state(branch: "feature", baseRef: "main", cwd: repo.path)
        XCTAssertTrue(state.isOnRemote)
        XCTAssertEqual(state.unpushed, 0)

        // Someone else moves main, and rewrites feature on the remote.
        let other = base.appendingPathComponent("other")
        git(["clone", "-q", remote.path, other.path], in: base)
        git(["config", "user.email", "o@o"], in: other); git(["config", "user.name", "O"], in: other)
        try commit("d.txt", "theirs", in: other)
        git(["push", "-q", "origin", "main"], in: other)
        git(["checkout", "-q", "feature"], in: other)
        git(["reset", "-q", "--hard", "HEAD~1"], in: other)
        try commit("e.txt", "diverged", in: other)
        git(["push", "-q", "--force", "origin", "feature"], in: other)

        XCTAssertTrue(Publishing.fetch(remote: "origin", cwd: repo.path).succeeded)
        state = Publishing.state(branch: "feature", baseRef: "main", cwd: repo.path)
        XCTAssertEqual(state.baseBehindRemote, 1, "main moved on the remote")
        XCTAssertEqual(state.remoteOnly, 1)

        try commit("f.txt", "mine", in: repo)
        let rejected = Publishing.push(branch: "feature", remote: "origin", cwd: repo.path)
        XCTAssertFalse(rejected.succeeded)
        XCTAssertTrue(rejected.message.contains("never force-pushes"), rejected.message)
    }

    func testWebHostsAreRecognised() {
        XCTAssertEqual(Publishing.webHost(for: "git@github.com:gazi/side.git"), .github(owner: "gazi", repo: "side"))
        XCTAssertEqual(Publishing.webHost(for: "https://github.com/gazi/side"), .github(owner: "gazi", repo: "side"))
        XCTAssertEqual(Publishing.webHost(for: "ssh://git@github.com/gazi/side.git"), .github(owner: "gazi", repo: "side"))
        XCTAssertEqual(Publishing.webHost(for: "https://gitlab.example.com/group/sub/repo.git"), .gitlab(host: "gitlab.example.com", path: "group/sub/repo"))
        XCTAssertEqual(Publishing.webHost(for: "ssh://git@gitlab.com:2222/group/repo.git"), .gitlab(host: "gitlab.com", path: "group/repo"))
        XCTAssertNil(Publishing.webHost(for: "/Users/me/remote.git"))
    }

    func testThePullRequestPageCarriesTitleAndBody() throws {
        let url = try XCTUnwrap(Publishing.newPullRequestURL(host: .github(owner: "o", repo: "r"), base: "main", branch: "feat/x", title: "Add C++ support", body: "Line"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/o/r/compare/main...feat/x?expand=1"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"), "a + must not become a space: \(url.absoluteString)")

        let checkpoint = { (intent: String, verification: CheckpointVerification?) -> Checkpoint in
            var c = Checkpoint(trackKey: "t", agentSessionId: UUID(), declaredIntent: intent, changedFilePaths: [], commandsRun: [],
                               provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""), gitCommitSHA: "abcdef1234")
            c.verification = verification
            return c
        }
        let body = Publishing.pullRequestBody(intent: "Billing v2", checkpoints: [
            checkpoint("Add the ledger", nil),
            checkpoint("Wire the API", CheckpointVerification(taskName: "test", command: "swift test", exitCode: 0, output: "")),
        ])
        XCTAssertTrue(body.hasPrefix("Billing v2\n\nChanges:\n- Add the ledger (abcdef1)\n- Wire the API (abcdef1)"), body)
        XCTAssertTrue(body.hasSuffix("Verified: test passed."), body)
    }
}
