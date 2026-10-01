import XCTest
@testable import Heron

/// Conversation history. `/new` used to delete the transcript, which is where a change's
/// reasoning lives — so the thing these tests care most about is that no path loses one.
final class ConversationHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store() -> AgentSessionStore { AgentSessionStore(stateDirectory: directory) }

    private func seed(_ store: AgentSessionStore, _ texts: [String], trackKey: String = "main") {
        for text in texts {
            store.appendTurn(AgentTurn(role: .user, content: [.text(text)]), trackKey: trackKey, providerId: "p", modelId: "m")
        }
    }

    func testArchivingKeepsTheConversationAndClearsTheLiveSlot() {
        let store = store()
        seed(store, ["how does the parser work?"])
        XCTAssertTrue(store.archiveActiveConversation(forTrackKey: "main"))
        XCTAssertNil(store.session(forTrackKey: "main")?.turns.first)
        let archived = store.archivedConversations(forTrackKey: "main")
        XCTAssertEqual(archived.count, 1)
        // Titled by what the user said, because that is what they recognize it by.
        XCTAssertEqual(archived.first?.title, "how does the parser work?")
        XCTAssertEqual(archived.first?.turnCount, 1)
    }

    func testAnEmptyConversationIsNotWorthArchiving() {
        let store = store()
        // Otherwise every /new on an untouched track files a blank row.
        XCTAssertFalse(store.archiveActiveConversation(forTrackKey: "main"))
        XCTAssertTrue(store.archivedConversations(forTrackKey: "main").isEmpty)
    }

    func testArchivesSurviveAReload() {
        let store = store()
        seed(store, ["first question"])
        store.archiveActiveConversation(forTrackKey: "main")
        let reloaded = self.store()
        XCTAssertEqual(reloaded.archivedConversations(forTrackKey: "main").count, 1)
        XCTAssertEqual(reloaded.archivedConversations(forTrackKey: "main").first?.title, "first question")
    }

    func testReopeningArchivesWhateverWasCurrentAndSwapsBackAndForth() throws {
        // Reopening must never be the move that loses the conversation you were in: the current
        // one is archived, and a second reopen swaps back without losing either.
        let store = store()
        seed(store, ["conversation A"])
        store.archiveActiveConversation(forTrackKey: "main")
        seed(store, ["conversation B"])

        func firstText(_ session: AgentSession?) -> String? {
            guard case .text(let value)? = session?.turns.first?.content.first else { return nil }
            return value
        }

        let a = try XCTUnwrap(store.archivedConversations(forTrackKey: "main").first { $0.title == "conversation A" })
        let reopened = try XCTUnwrap(store.openArchivedConversation(id: a.id, forTrackKey: "main"))
        XCTAssertEqual(firstText(reopened), "conversation A")
        XCTAssertEqual(firstText(store.session(forTrackKey: "main")), "conversation A")
        XCTAssertEqual(store.archivedConversations(forTrackKey: "main").map(\.title), ["conversation B"])

        let b = try XCTUnwrap(store.archivedConversations(forTrackKey: "main").first { $0.title == "conversation B" })
        store.openArchivedConversation(id: b.id, forTrackKey: "main")
        XCTAssertEqual(firstText(store.session(forTrackKey: "main")), "conversation B")
        XCTAssertEqual(store.archivedConversations(forTrackKey: "main").map(\.title), ["conversation A"])
    }

    func testArchivesAreScopedToTheirTrack() {
        let store = store()
        seed(store, ["on main"], trackKey: "main")
        store.archiveActiveConversation(forTrackKey: "main")
        seed(store, ["on feature"], trackKey: "feature")
        store.archiveActiveConversation(forTrackKey: "feature")

        XCTAssertEqual(store.archivedConversations(forTrackKey: "main").map(\.title), ["on main"])
        XCTAssertEqual(store.archivedConversations(forTrackKey: "feature").map(\.title), ["on feature"])
    }

    func testDeletingATrackTakesItsArchivesToo() {
        let store = store()
        seed(store, ["doomed"])
        store.archiveActiveConversation(forTrackKey: "main")
        store.removeSession(forTrackKey: "main")
        XCTAssertTrue(store.archivedConversations(forTrackKey: "main").isEmpty)
        XCTAssertTrue(self.store().archivedConversations(forTrackKey: "main").isEmpty)
    }

    func testNewestArchiveComesFirst() {
        let store = store()
        seed(store, ["older"])
        store.archiveActiveConversation(forTrackKey: "main")
        seed(store, ["newer"])
        store.archiveActiveConversation(forTrackKey: "main")
        XCTAssertEqual(store.archivedConversations(forTrackKey: "main").map(\.title), ["newer", "older"])
    }

    func testArchiveTitleComesFromWhatTheUserActuallySaid() {
        // An assistant-only transcript has no user phrasing to title it with, so the title is
        // empty. A compaction summary is a user-role turn Side wrote itself; using it as the title
        // tells the user nothing about which conversation this was, so it is skipped.
        func session(_ turns: [AgentTurn]) -> AgentSession {
            AgentSession(
                id: UUID(), trackKey: "main", providerId: "p", modelId: "m",
                turns: turns, createdAt: Date(), lastActiveAt: Date()
            )
        }
        XCTAssertTrue(ArchivedConversation.title(for: session([AgentTurn(role: .assistant, content: [.text("I spoke first")])])).isEmpty)

        let summary = AgentTurn(role: .user, content: [.text(ContextBudget.summaryTurnText("we fixed the parser"))])
        let real = AgentTurn(role: .user, content: [.text("now add a test for it")])
        XCTAssertEqual(ArchivedConversation.title(for: session([summary, real])), "now add a test for it")
    }
}
