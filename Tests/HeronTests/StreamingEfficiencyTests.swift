import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, step 4 (D6): Heron's own streaming path, from the provider's
/// thread to the transcript.
final class StreamEventCoalescerTests: XCTestCase {
    func testDeltasMergeAndOrderIsKept() {
        var pending: [AgentStreamEvent] = []
        for event: AgentStreamEvent in [.textDelta("a"), .textDelta("b"), .toolUseStart(id: "t", name: "read_file"),
                                        .toolUseInputDelta(id: "t", partialJSON: "{\"pa"), .toolUseInputDelta(id: "t", partialJSON: "th\"}"),
                                        .toolUseEnd(id: "t"), .thinkingDelta("x"), .thinkingDelta("y"), .textDelta("c")] {
            StreamEventCoalescer.merge(event, into: &pending)
        }
        let shape = pending.map { event -> String in
            switch event {
            case .textDelta(let text): return "text:\(text)"
            case .thinkingDelta(let text): return "thinking:\(text)"
            case .toolUseStart(let id, _): return "start:\(id)"
            case .toolUseInputDelta(_, let json): return "input:\(json)"
            case .toolUseEnd(let id): return "end:\(id)"
            default: return "other"
            }
        }
        XCTAssertEqual(shape, ["text:ab", "start:t", "input:{\"path\"}", "end:t", "thinking:xy", "text:c"])
    }
}

@MainActor
final class StreamingEfficiencyTests: XCTestCase {
    nonisolated private static let message = String((0..<50_000).map { index -> Character in index % 61 == 60 ? " " : Character(UnicodeScalar(97 + index % 26)!) })

    private func stream(duration: TimeInterval) throws -> (runner: AgentRunner, elapsed: TimeInterval, cpu: TimeInterval) {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("heron-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { _, _ in .streamedText(Self.message, delta: 10, duration: duration) }
        addTeardownBlock { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        addTeardownBlock { heron.cleanUp() }
        let cpuBefore = Self.processCPU()
        let start = Date()
        XCTAssertEqual(heron.send("Say a lot.", timeout: duration + 30), .finishedTurn)
        let elapsed = Date().timeIntervalSince(start)
        let cpu = Self.processCPU() - cpuBefore
        guard case .assistantText(let text)? = heron.runner.entries.last(where: { if case .assistantText = $0.kind { return true } else { return false } })?.kind else {
            XCTFail("no reply"); return (heron.runner, elapsed, cpu)
        }
        XCTAssertEqual(text, Self.message, "every delta, in order")
        return (heron.runner, elapsed, cpu)
    }

    private static func processCPU() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// 50,000 characters in 10-character deltas, as fast as they come: the main thread's share
    /// stays small and linear (it was a copy of the whole message per delta).
    func testAFastMessageCostsTheMainThreadLittle() throws {
        let (runner, _, _) = try stream(duration: 0)
        print("HERON stream fast: \(runner.streamingDeliveries) deliveries, \(String(format: "%.1f", runner.streamingDeliveryTime * 1000)) ms on the main thread")
        XCTAssertLessThanOrEqual(runner.streamingDeliveryTime, 0.020, "stream.heron: 20 ms")
    }

    /// The same message over two seconds: at most a hop a frame, whatever the delta rate
    /// (5,000 deltas here, 2,500 a second).
    func testAPacedMessageHopsAtMostOnceAFrame() throws {
        let (runner, elapsed, _) = try stream(duration: 2)
        let rate = Double(runner.streamingDeliveries) / elapsed
        print("HERON stream paced: \(runner.streamingDeliveries) deliveries in \(String(format: "%.2f", elapsed)) s (\(String(format: "%.0f", rate))/s), \(String(format: "%.1f", runner.streamingDeliveryTime * 1000)) ms on the main thread")
        XCTAssertLessThanOrEqual(rate, 60)
        XCTAssertLessThanOrEqual(runner.streamingDeliveryTime, 0.020)
    }

    /// The RFC's budget, 20 seconds of streaming: hops and a core's share. Opt-in with the other
    /// budgets (`SIDE_BUDGETS=1`), since it takes 20 seconds.
    func testTwentySecondsOfStreaming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_BUDGETS"] == "1", "set SIDE_BUDGETS=1 to measure")
        let (runner, elapsed, cpu) = try stream(duration: 20)
        let rate = Double(runner.streamingDeliveries) / elapsed
        let share = cpu / elapsed * 100
        print("BUDGET\t\(rate <= 60 ? "ok  " : "OVER")\tThink\tHeron streaming 20 s: main-thread hops\t\(String(format: "%.0f", rate)) /s\t≤ 60 /s")
        print("BUDGET\t\(share <= 15 ? "ok  " : "OVER")\tThink\tHeron streaming 20 s: CPU (with the fake server)\t\(String(format: "%.1f", share)) %\t≤ 15 %")
        XCTAssertLessThanOrEqual(rate, 60)
        XCTAssertLessThanOrEqual(share, 15)
    }
}
