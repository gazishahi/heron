import XCTest
@testable import Heron

/// Line counts on a checkpoint, and the pill that reads them back.
///
/// The bug these pin: Think's changed-files pill was rebuilt from in-memory state and so vanished
/// on relaunch, while Review went on showing the very same diffs from the durable record. Two
/// surfaces describing one set of changes must not disagree because a process restarted.
final class CheckpointFileChangeTests: XCTestCase {

    private func checkpoint(
        session: UUID, paths: [String], changes: [CheckpointFileChange], at date: Date = Date()
    ) -> Checkpoint {
        Checkpoint(
            trackKey: "main", agentSessionId: session, declaredIntent: "did a thing",
            changedFilePaths: paths, commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""),
            gitCommitSHA: "abc123", fileChanges: changes
        )
    }

    func testLineCountsSurviveAPersistenceRoundTrip() throws {
        let original = checkpoint(
            session: UUID(), paths: ["a.swift"],
            changes: [CheckpointFileChange(path: "a.swift", added: 12, removed: 3)]
        )
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.fileChanges, original.fileChanges)
    }

    func testACheckpointFromAnOlderBuildStillDecodes() throws {
        // Tolerant decoding, same contract as every other persisted struct here. The exact hazard
        // the audit named: a persisted file missing fields a newer build added. Synthesized
        // Codable treats each one as a hard failure, which takes the whole conversation down;
        // Checkpoint decodes what's missing with defaults instead. This fixture predates ids,
        // provenance, the commit SHA, line counts and verification — its file list is intact and
        // everything else is simply absent — never zeros pretending to be measurements.
        let json = #"{"trackKey":"feature","declaredIntent":"tidy up","changedFilePaths":["a.swift"]}"#
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.trackKey, "feature")
        XCTAssertEqual(decoded.declaredIntent, "tidy up")
        XCTAssertEqual(decoded.changedFilePaths, ["a.swift"])
        XCTAssertEqual(decoded.commandsRun, [])
        XCTAssertNil(decoded.gitCommitSHA)
        XCTAssertEqual(decoded.provenance.modelId, "")
        XCTAssertTrue(decoded.fileChanges.isEmpty)
        XCTAssertNil(decoded.verification)
    }

    // MARK: - Counting a diff

    func testLineDeltaCountsOnlyAddedAndRemovedLines() {
        // `+++ b/file` and `--- a/file` start with + and -, and counting them inflated every
        // single-file edit by one added and one removed line. Context lines and hunk headers
        // are not counted either, and an empty diff counts nothing.
        let diff = """
            --- a/x.swift
            +++ b/x.swift
            @@ -1,2 +1,3 @@
             context
            -gone
            +new
            +also new
            @@ -10,3 +11,3 @@
             one
             two
             three
            """
        let cases: [(name: String, diff: String, added: Int, removed: Int)] = [
            ("headers and context ignored", diff, 2, 1),
            ("empty diff", "", 0, 0),
            ("context only", "@@ -1,3 +1,3 @@\n one\n two\n three", 0, 0),
        ]
        for row in cases {
            let delta = AgentRunner.lineDelta(in: row.diff)
            XCTAssertEqual(delta.added, row.added, "\(row.name): added")
            XCTAssertEqual(delta.removed, row.removed, "\(row.name): removed")
        }
    }
}
