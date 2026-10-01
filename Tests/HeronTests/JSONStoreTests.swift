import XCTest
@testable import Heron

final class JSONStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jsonstore-tests-\(UUID().uuidString)")
        PersistenceFailureReporter.shared.resetCounts()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private struct Sample: Codable, Equatable {
        var name: String
        var count: Int
    }

    func testRoundTripStampsTheCurrentSchemaVersion() {
        let target = url("sample.json")
        XCTAssertTrue(JSONStore.write(Sample(name: "a", count: 1), to: target))

        let loaded = JSONStore.read(Sample.self, from: target)
        XCTAssertEqual(loaded?.payload, Sample(name: "a", count: 1))
        XCTAssertEqual(loaded?.version, JSONStore.currentVersion)
    }

    func testALegacyFileReadsAsVersionOneAndUpgradesWhenRewritten() throws {
        // Every file written before the envelope existed had the payload at the top level.
        // Refusing to read those would have looked exactly like data loss to the user.
        let target = url("legacy.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"name":"legacy","count":7}"#.utf8).write(to: target)

        let loaded = try XCTUnwrap(JSONStore.read(Sample.self, from: target))
        XCTAssertEqual(loaded.payload, Sample(name: "legacy", count: 7))
        XCTAssertEqual(loaded.version, 1)

        // Rewriting it upgrades the file in place.
        var payload = loaded.payload
        payload.count = 8
        JSONStore.write(payload, to: target)

        let reloaded = JSONStore.read(Sample.self, from: target)
        XCTAssertEqual(reloaded?.version, JSONStore.currentVersion)
        XCTAssertEqual(reloaded?.payload.count, 8)
    }

    func testMissingFileIsNotAFailure() {
        var reported = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PersistenceFailureReporter.failureNotification, object: nil, queue: .main
        ) { _ in reported += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertNil(JSONStore.read(Sample.self, from: url("never-written.json")))
        XCTAssertEqual(reported, 0, "First run has no file yet — that isn't an error worth alarming anyone about.")
    }

    func testACorruptFileIsReportedAndQuarantinedRatherThanSilentlyEmpty() throws {
        // Audit H3: a corrupt store is quarantined, not overwritten.
        let target = url("corrupt.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{not json at all".utf8)
        try garbage.write(to: target)

        let expectation = expectation(forNotification: PersistenceFailureReporter.failureNotification, object: nil) { note in
            guard let failure = note.object as? PersistenceFailureReporter.Failure else { return false }
            return failure.operation == .read && failure.url == target
        }

        XCTAssertNil(JSONStore.read(Sample.self, from: target))
        wait(for: [expectation], timeout: 2)

        // The original is gone from its path — so a loader's `?? []` followed by `save()`
        // writes a fresh file rather than clobbering the evidence.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let quarantined = siblings.first(where: { $0.hasPrefix("corrupt.json.corrupt-") }) else {
            return XCTFail("no quarantine file among \(siblings)")
        }
        XCTAssertEqual(try Data(contentsOf: url(quarantined)), garbage)

        // And the store carries on: the next save lands at the original path.
        XCTAssertTrue(JSONStore.write(Sample(name: "fresh", count: 1), to: target))
        XCTAssertEqual(JSONStore.read(Sample.self, from: target)?.payload.count, 1)
    }

    func testUnwritableLocationIsReportedAndReturnsFalse() {
        // A path whose parent is a *file*, not a directory: createDirectory fails, so the write
        // can't land. Stands in for the real cases (full disk, read-only volume, revoked
        // permission) that used to vanish into `try?`.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = url("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let target = blocker.appendingPathComponent("nested.json")

        let expectation = expectation(forNotification: PersistenceFailureReporter.failureNotification, object: nil) { note in
            (note.object as? PersistenceFailureReporter.Failure)?.operation == .write
        }

        XCTAssertFalse(JSONStore.write(Sample(name: "a", count: 1), to: target))
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Tolerant decoding

    func testSessionFromAnOlderBuildStillLoads() throws {
        // The exact hazard the audit named: a persisted file missing fields a newer build
        // added. Synthesized Codable treats each one as a hard failure, which takes the whole
        // conversation down; these types decode what's missing with defaults instead.
        // Built by encoding a current session and deleting the fields a hypothetical older
        // build wouldn't have written, so the fixture can't drift from the real wire shape.
        var session = AgentSession(trackKey: "feature", providerId: "anthropic", modelId: "claude-sonnet-5")
        session.turns = [AgentTurn(role: .user, content: [.text("hello")])]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(session)) as? [String: Any]
        )
        for key in ["id", "providerId", "modelId", "createdAt", "lastActiveAt"] { object.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recovered = try decoder.decode(AgentSession.self, from: data)

        XCTAssertEqual(recovered.trackKey, "feature")
        XCTAssertEqual(recovered.turns.count, 1)
        XCTAssertEqual(recovered.providerId, "")
    }

    func testSessionStillRequiresTheFieldsThatMakeItMeaningful() {
        // Tolerance has a floor: a file with no track key isn't an older session, it's not a
        // session at all, and quietly inventing one would attach a conversation to the wrong
        // track.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(AgentSession.self, from: Data(#"{"turns":[]}"#.utf8)))
    }
}
