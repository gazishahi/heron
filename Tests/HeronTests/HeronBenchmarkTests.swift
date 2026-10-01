import XCTest
@testable import Heron

/// The token benchmark (SIDE_RFC_HERON_EFFICIENCY.md, Q3): a few fixed tasks on the fixture
/// project, against the real API with the person's own key, and what each one cost. Opt-in:
/// it spends money (about $1 a run on Sonnet 5). `scripts/heron-bench.sh` runs it.
///
///   SIDE_HERON_BENCH=1              run it
///   SIDE_HERON_BENCH_MODEL=…        the model (claude-sonnet-5)
///   SIDE_HERON_BENCH_OUT=path.json  where the report goes
@MainActor
final class HeronBenchmarkTests: XCTestCase {
    struct Task {
        let name: String
        let mode: AgentMode
        let prompt: String
    }

    static let tasks: [Task] = [
        Task(name: "explain", mode: AgentMode(scope: .ask, autonomy: .manual),
             prompt: "Explain how an order moves from creation to shipment in this project: which types and functions are involved, in order, and where stock and payment are handled. Cite the files."),
        Task(name: "discounts", mode: AgentMode(scope: .ask, autonomy: .manual),
             prompt: "How is the price of an order computed when the customer has a loyalty tier and also uses a coupon that doesn't stack with loyalty? Walk through it with the code, and say whether shipping can end up free because of the discounts."),
        Task(name: "cancel", mode: AgentMode(scope: .build, autonomy: .full),
             prompt: "Add a way to cancel an order: OrderService.cancelOrder(orderID:reason:) that's allowed until the order is packed, puts reserved stock back, voids the payment authorization if there is one, and notifies the customer. Follow the style of the surrounding code."),
    ]

    /// Stops the run past this many dollars, whatever's left.
    static let spendCap = 3.0

    struct Result: Codable {
        let task: String
        let model: String
        let phase: String
        let requests: Int
        let inputTokens: Int
        let cachedInputTokens: Int
        let cacheWriteInputTokens: Int
        let outputTokens: Int
        let dollars: Double
        let seconds: Double
    }

    static func projectCopy() throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/BenchProject")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("heron-bench-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: copy)
        // A repository, as a real project is: checkpoints are commits.
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=Bench", "-c", "user.email=bench@example.com", "commit", "-qm", "fixture"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = copy
            try git.run()
            git.waitUntilExit()
        }
        return copy
    }

    func testTheBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SIDE_HERON_BENCH"] == "1", "set SIDE_HERON_BENCH=1 to spend about $1 on the benchmark")
        try XCTSkipUnless((environment["ANTHROPIC_API_KEY"] ?? "").count > 10, "needs ANTHROPIC_API_KEY")
        let model = environment["SIDE_HERON_BENCH_MODEL"] ?? "claude-sonnet-5"
        var results: [Result] = []
        var spent = 0.0
        for task in Self.tasks where (environment["SIDE_HERON_BENCH_TASKS"].map { $0.split(separator: ",").contains(Substring(task.name)) } ?? true) {
            guard spent < Self.spendCap else { print("HERONBENCH stopped: $\(spent) spent, cap $\(Self.spendCap)"); break }
            let project = try Self.projectCopy()
            defer { try? FileManager.default.removeItem(at: project) }
            let heron = try HeadlessHeron(project: project, baseURL: nil, modelId: model, mode: task.mode)
            defer { heron.cleanUp() }
            let started = Date()
            let phase = heron.send(task.prompt, timeout: 600)
            let totals = heron.totals
            let dollars = ModelPricing.estimatedCost(modelId: model, totals: totals) ?? 0
            spent += dollars
            let result = Result(task: task.name, model: model, phase: "\(phase)", requests: totals.requestCount,
                                inputTokens: totals.inputTokens, cachedInputTokens: totals.cachedInputTokens,
                                cacheWriteInputTokens: totals.cacheWriteInputTokens, outputTokens: totals.outputTokens,
                                dollars: dollars, seconds: Date().timeIntervalSince(started))
            results.append(result)
            print(String(format: "HERONBENCH %@\t%@\t%d requests\tinput %d\tcached %d\twritten %d\toutput %d\t$%.4f\t%.0f s",
                         task.name, result.phase, result.requests, result.inputTokens, result.cachedInputTokens,
                         result.cacheWriteInputTokens, result.outputTokens, dollars, result.seconds))
            for entry in heron.runner.entries { if case .failure(let message) = entry.kind { print("HERONBENCH \(task.name) failed: \(message)") } }
            XCTAssertEqual(phase, .finishedTurn, "\(task.name): the task should finish")
            if task.name == "cancel" {
                let changed = (try? String(contentsOf: project.appendingPathComponent("Sources/Shop/OrderService.swift"), encoding: .utf8)) ?? ""
                XCTAssertTrue(changed.contains("cancelOrder"), "the edit was applied")
            }
        }
        print(String(format: "HERONBENCH total\t$%.4f", spent))
        if let out = environment["SIDE_HERON_BENCH_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: out))
        }
    }
}
