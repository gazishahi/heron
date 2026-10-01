import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md: what Heron sends, measured against a fake server. A scripted
/// session (two messages, ten tool round trips each, reading real files) records every request
/// body. Step 1 measured the baseline (consecutive requests shared nothing a cache could serve);
/// step 2's test holds each request to repeating the previous one and adding to the end.
@MainActor
final class HeronRequestMeasurementTests: XCTestCase {
    /// A project of twelve files, a few hundred lines each: what an agent reads to answer.
    static func fixtureProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heron-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        for file in 0..<12 {
            let lines = (0..<180).map { line in "    func step\(file)_\(line)(_ value: Int) -> Int { value &* \(line + 1) &+ \(file) }  // part \(line)" }
            try (["struct Part\(file) {"] + lines + ["}"]).joined(separator: "\n")
                .write(to: root.appendingPathComponent("Sources/Part\(file).swift"), atomically: true, encoding: .utf8)
        }
        return root
    }

    struct Measurement {
        var bodies: [Int] = []
        /// Bytes identical to the previous request's start.
        var sharedWithPrevious: [Int] = []
        var total: Int { bodies.reduce(0, +) }
        var reusable: Int { sharedWithPrevious.reduce(0, +) }
    }

    static func measure(_ bodies: [Data]) -> Measurement {
        var result = Measurement()
        var previous = Data()
        for body in bodies {
            let shared = zip(previous, body).prefix { $0 == $1 }.count
            result.bodies.append(body.count)
            result.sharedWithPrevious.append(shared)
            previous = body
        }
        return result
    }

    /// A request with its cache markers taken out, as the API renders it: tools, then system,
    /// then each message. The strings are sorted-key JSON, so equal content is equal bytes.
    struct Rendered {
        var tools: String
        var system: String
        var messages: [String]
        var breakpoints: Int
        /// Bytes after the last breakpoint (the part no cache serves).
        var pastLastBreakpoint: Int
    }

    static func render(_ body: Data) throws -> Rendered {
        var breakpoints = 0
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object.removeValue(forKey: "cache_control") != nil { breakpoints += 1 }
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        func json(_ value: Any?) throws -> String {
            guard let value else { return "" }
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Where the last breakpoint is: the last message's last block carries it, or nothing does.
        let rawMessages = object["messages"] as? [[String: Any]] ?? []
        let lastMarked = rawMessages.lastIndex { (($0["content"] as? [[String: Any]])?.last?["cache_control"]) != nil }
        let messages = try rawMessages.map { try json(strip($0)) }
        let past = lastMarked.map { messages[($0 + 1)...].reduce(0) { $0 + $1.utf8.count } } ?? messages.reduce(0) { $0 + $1.utf8.count }
        return Rendered(tools: try json(object["tools"].map(strip)), system: try json(object["system"].map(strip)),
                        messages: messages, breakpoints: breakpoints, pastLastBreakpoint: past)
    }

    /// SIDE_RFC_HERON_EFFICIENCY.md, D1 and its budgets: in a scripted session of 22 round trips
    /// (two messages, one with an `@`-mention), every request repeats the previous one exactly
    /// and adds to the end, and nothing past the last breakpoint goes uncached.
    func testEachRequestRepeatsThePreviousOneAndAddsToTheEnd() throws {
        let project = try Self.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        // Each request reads the next file; the tenth of each message answers.
        let server = try FakeModelServer { index, _ in
            let step = index % 11
            if step == 10 { return .text("Read them. Each part multiplies and adds its own index.") }
            return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(step).swift"}"#)])
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }

        XCTAssertEqual(heron.send("Read the parts, starting with @Sources/Part0.swift, and say what they do."), .finishedTurn)
        XCTAssertEqual(heron.send("Now read them again and compare the last two."), .finishedTurn)
        let bodies = server.requests
        XCTAssertEqual(bodies.count, 22)
        let rendered = try bodies.map(Self.render)

        var identical = 0
        var worstExcess = Int.min
        for (index, request) in rendered.enumerated() {
            XCTAssertEqual(request.breakpoints, 2, "request \(index): the system prompt's and the last message's")
            XCTAssertEqual(request.pastLastBreakpoint, 0, "request \(index)")
            guard index > 0 else { continue }
            let previous = rendered[index - 1]
            let repeats = request.tools == previous.tools && request.system == previous.system
                && request.messages.count > previous.messages.count && Array(request.messages.prefix(previous.messages.count)) == previous.messages
            if repeats { identical += 1 } else { XCTFail("request \(index) changed what request \(index - 1) sent") }
            // Re-sent past the previous request's breakpoint, beyond what this round trip added.
            let added = request.messages.dropFirst(previous.messages.count).reduce(0) { $0 + $1.utf8.count }
            worstExcess = max(worstExcess, request.pastLastBreakpoint - added)
        }
        XCTAssertEqual(identical, rendered.count - 1, "every request repeats the one before")
        XCTAssertLessThanOrEqual(worstExcess, 2_000)
        // The mention's note is stored with the typed message and sent with it every time.
        XCTAssertTrue(rendered[0].messages[0].contains("their contents are not included"))
        XCTAssertTrue(rendered.allSatisfy { $0.messages[0] == rendered[0].messages[0] })
        let transcriptText = heron.runner.entries.compactMap { if case .userText(let text) = $0.kind { return text } else { return nil } }
        XCTAssertEqual(transcriptText.first, "Read the parts, starting with @Sources/Part0.swift, and say what they do.", "the note isn't in the bubble")

        let measured = Self.measure(bodies)
        print("HERON caching: \(bodies.count) requests, \(measured.total) bytes sent, \(identical) of \(rendered.count - 1) repeat the previous request")
        print("HERON caching: uncached bytes past the last breakpoint, worst request: \(rendered.map(\.pastLastBreakpoint).max() ?? 0)")
        XCTAssertEqual(heron.totals.requestCount, 22, "every request metered")
    }
}

/// The headless driver applies an edit at full autonomy, as the benchmark's Build task needs.
@MainActor
final class HeadlessHeronTests: XCTestCase {
    func testAnEditIsAppliedWithoutAClick() throws {
        let project = try HeronBenchmarkTests.projectCopy()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            index == 0
                ? .tools([(name: "edit_file", input: ##"{"path": "README.md", "old_string": "# Shop", "new_string": "# Shop (edited)"}"##)])
                : .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .build, autonomy: .full))
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Mark the readme."), .finishedTurn)
        XCTAssertTrue(try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8).hasPrefix("# Shop (edited)"))
        XCTAssertEqual(server.requests.count, 2)
    }

    /// A command the model proposes is refused, and the turn goes on to finish (the benchmark
    /// runs no commands).
    func testACommandIsRefusedAndTheTurnFinishes() throws {
        let project = try HeronBenchmarkTests.projectCopy()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            index == 0 ? .tools([(name: "run_shell_command", input: #"{"command": "swift build"}"#)]) : .text("Couldn't build; fine.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .build, autonomy: .full))
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Build it.", timeout: 30), .finishedTurn)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(String(decoding: server.requests[1], as: UTF8.self).contains("tool_result"), "the refusal went back to the model")
    }
}
