import XCTest
@testable import Heron

/// REL-2 (2026-09-30 audit): git is found in any developer directory, without running anything.
final class DeveloperToolsTests: XCTestCase {
    func testGitIsFoundInAnyDeveloperDirectory() {
        XCTAssertTrue(DeveloperTools.gitInstalled(environment: [:]) { $0 == "/Library/Developer/CommandLineTools/usr/bin/git" })
        XCTAssertTrue(DeveloperTools.gitInstalled(environment: [:]) { $0 == "/Applications/Xcode.app/Contents/Developer/usr/bin/git" })
        XCTAssertTrue(DeveloperTools.gitInstalled(environment: ["DEVELOPER_DIR": "/X/Developer"]) { $0 == "/X/Developer/usr/bin/git" })
        XCTAssertFalse(DeveloperTools.gitInstalled(environment: [:]) { _ in false }, "no tools: missing, and the stub isn't run")
    }
}
