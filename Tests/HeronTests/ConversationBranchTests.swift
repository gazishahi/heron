import XCTest
@testable import Heron

/// Forking a conversation at an edited message.
///
/// The invariant every test here defends: **nothing is deleted.** A rewound turn may have applied
/// an edit that is still on disk and still in Review as a checkpoint, so a branch the user cannot
/// reach would leave those checkpoints belonging to a conversation that, as far as the app is
/// concerned, never happened.
final class ConversationBranchTests: XCTestCase {
    private var directory: URL!
    private let track = "feature-track"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> AgentSessionStore {
        AgentSessionStore(stateDirectory: directory)
    }

    @discardableResult
    private func append(_ store: AgentSessionStore, _ role: AgentMessage.Role, _ text: String) -> AgentTurn {
        let turn = AgentTurn(role: role, content: [.text(text)])
        store.appendTurn(turn, trackKey: track, providerId: "anthropic", modelId: "m")
        return turn
    }

    /// user/assistant/user/assistant, returning the turns in order.
    private func seedFourTurns(_ store: AgentSessionStore) -> [AgentTurn] {
        [
            append(store, .user, "first ask"),
            append(store, .assistant, "first answer"),
            append(store, .user, "second ask"),
            append(store, .assistant, "second answer"),
        ]
    }

    // MARK: - The fork

    func testTheForkHasTheRightShape() {
        // The live conversation rewinds to just before the edited turn; the removed turns include
        // the edited one itself — it is being replaced, so the caller must count it when working
        // out what those turns already did; the branch is identifiable as one and records where it
        // diverged; it is titled by the message being edited away, not the conversation's *first*
        // message (the branch and its parent share that prefix, so the ordinary title would file
        // both under the same name); it takes a fresh id so it cannot collide with the live
        // conversation; and it appears in the history picker.
        let store = makeStore()
        let turns = seedFourTurns(store)
        let liveId = store.session(forTrackKey: track)?.id
        XCTAssertNotNil(liveId)
        guard let branch = store.branchConversation(atTurnId: turns[2].id, forTrackKey: track) else {
            return XCTFail("branch failed")
        }

        let live = store.session(forTrackKey: track)
        XCTAssertEqual(live?.turns.count, 2)
        XCTAssertEqual(live?.turns.map(\.id), [turns[0].id, turns[1].id])
        XCTAssertEqual(live?.id, liveId)

        XCTAssertEqual(branch.removedTurns.map(\.id), [turns[2].id, turns[3].id])
        XCTAssertEqual(branch.record.isBranch, true)
        XCTAssertEqual(branch.record.branchPointTurnIndex, 2)
        XCTAssertEqual(branch.record.title, "second ask")
        XCTAssertNotEqual(branch.record.id, liveId)

        XCTAssertEqual(store.archivedConversations(forTrackKey: track).count, 1)
        XCTAssertEqual(store.archivedConversations(forTrackKey: track).first?.isBranch, true)

        // The title skips a leading image block and uses the message's text.
        let withImage = AgentTurn(role: .user, content: [.image(mediaType: "image/png", base64: "AAAA"), .text("and this")])
        store.appendTurn(withImage, trackKey: track, providerId: "anthropic", modelId: "m")
        XCTAssertEqual(store.branchConversation(atTurnId: withImage.id, forTrackKey: track)?.record.title, "and this")
    }

    func testTheBranchKeepsTheConversationWholeNotJustTheDiscardedTail() {
        let store = makeStore()
        let turns = seedFourTurns(store)
        guard let branch = store.branchConversation(atTurnId: turns[2].id, forTrackKey: track) else {
            return XCTFail("branch failed")
        }
        // A tail-only archive would be a fragment every reader would have to reassemble. Opening
        // a branch has to give an ordinary, complete conversation.
        let reopened = store.openArchivedConversation(id: branch.record.id, forTrackKey: track)
        XCTAssertEqual(reopened?.turns.map(\.id), turns.map(\.id))
    }

    func testTheForkSurvivesARelaunch() {
        let store = makeStore()
        let turns = seedFourTurns(store)
        store.branchConversation(atTurnId: turns[2].id, forTrackKey: track)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.session(forTrackKey: track)?.turns.count, 2)
        let archived = reloaded.archivedConversations(forTrackKey: track)
        XCTAssertEqual(archived.count, 1)
        // The branch flag is what the picker labels the row with; losing it on reload would make
        // a branch indistinguishable from a conversation the user started deliberately.
        XCTAssertEqual(archived.first?.branchPointTurnIndex, 2)
    }

    // MARK: - Forking the first message

    func testEditingTheFirstMessageEmptiesTheLiveConversation() {
        let store = makeStore()
        let turns = seedFourTurns(store)
        let branch = store.branchConversation(atTurnId: turns[0].id, forTrackKey: track)
        XCTAssertEqual(store.session(forTrackKey: track)?.turns.isEmpty, true)
        XCTAssertEqual(branch?.removedTurns.count, 4)
        // And the whole original is still readable.
        XCTAssertEqual(branch?.record.turnCount, 4)
    }

    // MARK: - Refusals

    func testAnAssistantTurnCannotBeForkedAt() {
        let store = makeStore()
        let turns = seedFourTurns(store)
        // Editing what the agent said would let a user fabricate agent output, which the
        // constitution's attributability requirement rules out.
        XCTAssertNil(store.branchConversation(atTurnId: turns[1].id, forTrackKey: track))
        XCTAssertEqual(store.session(forTrackKey: track)?.turns.count, 4)
    }

    func testForkRefusalsLeaveTheConversationAlone() {
        // An unknown turn, a track with no conversation, and a turn that belongs to another track
        // all fork nothing — and the live conversation is untouched by the attempt.
        let store = makeStore()
        let mine = seedFourTurns(store)
        XCTAssertNil(store.branchConversation(atTurnId: UUID(), forTrackKey: track))
        XCTAssertEqual(store.session(forTrackKey: track)?.turns.count, 4)

        XCTAssertNil(store.branchConversation(atTurnId: UUID(), forTrackKey: "empty"))

        let theirs = AgentTurn(role: .user, content: [.text("other track")])
        store.appendTurn(theirs, trackKey: "other", providerId: "anthropic", modelId: "m")
        XCTAssertNil(store.branchConversation(atTurnId: theirs.id, forTrackKey: track))
        XCTAssertEqual(store.session(forTrackKey: track)?.turns.count, mine.count)
        XCTAssertTrue(store.archivedConversations(forTrackKey: track).isEmpty)
    }

    // MARK: - Repeated forks

    func testForkingTwiceLeavesTwoBranchesAndOneLiveConversation() {
        let store = makeStore()
        let turns = seedFourTurns(store)
        store.branchConversation(atTurnId: turns[2].id, forTrackKey: track)
        let replacement = append(store, .user, "second ask, reworded")
        append(store, .assistant, "better answer")
        store.branchConversation(atTurnId: replacement.id, forTrackKey: track)

        XCTAssertEqual(store.archivedConversations(forTrackKey: track).count, 2)
        XCTAssertEqual(store.session(forTrackKey: track)?.turns.count, 2)
        XCTAssertTrue(store.archivedConversations(forTrackKey: track).allSatisfy(\.isBranch))
    }
}
