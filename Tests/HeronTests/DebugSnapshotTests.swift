import XCTest
@testable import Heron

/// SIDE_RFC_DEBUGGER.md, step 5: the agent reads a paused program (Q5, read-only).
final class DebugSnapshotTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/side-debug-snapshot-\(UUID().uuidString)")

    override func tearDown() { DebugSnapshot.shared.publish(nil, projectRoot: root) }

    func testWithoutASessionTheToolSaysSo() {
        let output = DebugSnapshot.shared.report(projectRoot: root)
        XCTAssertTrue(output.contains("No debugging session"), output)
        XCTAssertTrue(output.contains("can't start or control it"), output)
    }

    func testAPausedProgramReadsAsStackLocalsAndWatches() {
        var state = DebugSnapshot.State(program: "DebugDemo", adapter: "LLDB", status: .paused)
        state.reason = "exception"
        state.exception = "Fatal error: Index out of range"
        state.frames = [
            DebugSnapshot.Frame(name: "swift_willThrow", path: nil, line: 0),
            DebugSnapshot.Frame(name: "check(_:)", path: "Sources/DebugDemo/main.swift", line: 15),
        ]
        state.selectedFrame = 1
        state.locals = [
            DebugSnapshot.Variable(name: "total", type: "Int", value: "145"),
            DebugSnapshot.Variable(name: "point", type: "Point", value: "Point", children: [
                DebugSnapshot.Variable(name: "x", type: "Int", value: "3"),
                DebugSnapshot.Variable(name: "y", type: "Int", value: "6"),
            ]),
        ]
        state.watches = [(expression: "total * 2", value: "290")]
        state.output = "How many points?\n"
        DebugSnapshot.shared.publish(state, projectRoot: root)

        let output = DebugSnapshot.shared.report(projectRoot: root)
        XCTAssertTrue(output.hasPrefix("Debugging \u{201C}DebugDemo\u{201D} with LLDB: paused on an exception."), output)
        XCTAssertTrue(output.contains("Exception: Fatal error: Index out of range"))
        XCTAssertTrue(output.contains("#0 swift_willThrow  (no source)"))
        XCTAssertTrue(output.contains("#1 check(_:)  Sources/DebugDemo/main.swift:15  \u{2190} selected"))
        XCTAssertTrue(output.contains("Locals in frame #1:"))
        XCTAssertTrue(output.contains("  total: Int = 145"))
        XCTAssertTrue(output.contains("    x: Int = 3"), "members are indented under their value")
        XCTAssertTrue(output.contains("total * 2 = 290"))
        XCTAssertTrue(output.contains("How many points?"))
    }

    func testARunningProgramHasNoStackToShow() {
        DebugSnapshot.shared.publish(DebugSnapshot.State(program: "app.ts", adapter: "js-debug", status: .running), projectRoot: root)
        let output = DebugSnapshot.shared.report(projectRoot: root)
        XCTAssertTrue(output.contains(": running."), output)
        XCTAssertTrue(output.contains("known only while it's paused"), output)
        XCTAssertFalse(output.contains("Stack"))
    }

    func testTheReportIsBounded() {
        var state = DebugSnapshot.State(program: "deep", adapter: "LLDB", status: .paused)
        state.frames = (0..<500).map { DebugSnapshot.Frame(name: "recurse", path: "a.c", line: $0) }
        state.locals = (0..<500).map { DebugSnapshot.Variable(name: "v\($0)", type: nil, value: String(repeating: "x", count: 10_000)) }
        state.output = String(repeating: "log line\n", count: 10_000)
        DebugSnapshot.shared.publish(state, projectRoot: root)
        let output = DebugSnapshot.shared.report(projectRoot: root)
        XCTAssertTrue(output.contains("and 480 more."))
        XCTAssertTrue(output.contains("and 470 more."))
        XCTAssertLessThan(output.count, 12_000)
    }

    func testTheToolIsThereInEveryScopeAndReadsTheSnapshot() {
        for scope in AgentToolScope.allCases {
            XCTAssertTrue(ToolExecutor.specs(for: scope).contains { $0.name == "read_debug_state" }, "\(scope)")
        }
        DebugSnapshot.shared.publish(DebugSnapshot.State(program: "tool", adapter: "Delve", status: .ended), projectRoot: root)
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        guard case .completed(let output, let isError) = executor.execute(name: "read_debug_state", input: .object([:]), toolUseId: "t1", scope: .ask) else {
            return XCTFail("expected a result")
        }
        XCTAssertFalse(isError)
        XCTAssertTrue(output.contains("with Delve: ended."), output)
    }
}
