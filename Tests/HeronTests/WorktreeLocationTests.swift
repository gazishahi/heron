import XCTest
@testable import Heron

final class WorktreeLocationTests: XCTestCase {
    /// Tests make tracks by the hundred; their worktrees must never land in the person's own
    /// Application Support (they did: ~480 folders from test runs).
    func testTestWorktreesStayOutOfApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertFalse(GitPaths.worktreesSupportDirectory.path.hasPrefix(support.path))
        XCTAssertTrue(GitPaths.worktreesSupportDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
