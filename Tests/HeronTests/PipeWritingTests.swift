import XCTest
@testable import Heron

/// 2026-09-30 audit, H1: writing to a child that has exited raised SIGPIPE and ended the whole
/// process. This test process doesn't ignore SIGPIPE, so if `PipeWriting` didn't protect the
/// descriptor, the test runner itself would die here.
final class PipeWritingTests: XCTestCase {
    func testWritingToAnExitedReaderFailsInsteadOfKillingUs() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let stdin = Pipe()
        process.standardInput = stdin
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        // More than a pipe's buffer, so the write can't just land in it.
        let large = Data(repeating: 0x61, count: 300_000)
        XCTAssertFalse(PipeWriting.write(large, to: stdin.fileHandleForWriting))
        XCTAssertFalse(PipeWriting.write(Data("again".utf8), to: stdin.fileHandleForWriting), "and again, still alive")
    }

    func testWritingToALiveReaderSucceeds() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        XCTAssertTrue(PipeWriting.write(Data("hello".utf8), to: stdin.fileHandleForWriting))
        try stdin.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "hello")
    }
}

/// 2026-09-30 audit, H7: an agent that exits on its own left its pipe handlers being called
/// with nothing, about 400,000 times a second, until the app quit.
@MainActor
final class ExitedChildIdleTests: XCTestCase {
    private static func processCPU() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    func testAnAgentThatExitsLeavesNothingRunning() throws {
        let launch = ACPLaunch(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        let connection = try ACPConnection(launch: launch, cwd: FileManager.default.temporaryDirectory)
        // Let it exit and its end of file arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = Self.processCPU()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let spent = Self.processCPU() - before
        XCTAssertLessThan(spent, 0.2, "CPU over a second after the agent exited: \(spent) s")
        _ = connection
    }
}

/// 2026-09-30 audit, H12 (launch gate 4): only agents verified with Side are shown without the
/// experimental label.
final class OutsideAgentLabelTests: XCTestCase {
    func testOnlyVerifiedAgentsGoUnlabelled() {
        let verified = ACPAgent.builtIn.filter(\.isVerified).map(\.id)
        XCTAssertEqual(verified, ["claude-code"])
        XCTAssertFalse(ACPAgent.builtIn.first { $0.id == "codex" }?.isVerified ?? true)
    }
}
