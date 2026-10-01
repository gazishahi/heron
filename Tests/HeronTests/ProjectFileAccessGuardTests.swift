import XCTest
@testable import Heron

/// The write and read guards on Side's own directories inside a project.
///
/// The default macOS filesystem is case-insensitive, so `.GIT/hooks/x` *is* `.git/hooks/x`. An
/// exact-string guard let the first spelling through, and a write there is code execution on the
/// next unattended `git status` — found and verified by the 2026-09-01 audit.
final class ProjectFileAccessGuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/side-guard-\(UUID().uuidString)")

    private func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func testWriteGuard() {
        // `.git` and `.side` are not writable in any casing, nor is the root itself; ordinary
        // files — including look-alikes such as `.gitignore` and `.github` — are.
        let cases: [(URL, Bool)] = [
            (url(".git/config"), false), (url(".GIT/config"), false), (url(".Git/hooks/post-checkout"), false),
            (url(".gIt/HEAD"), false), (url(".side/tracks.json"), false), (url(".SIDE/tracks.json"), false),
            (url(".Side/think/index.json"), false), (root, false),
            (url("src/main.swift"), true), (url("README.md"), true), (url(".gitignore"), true),
            (url(".github/workflows/ci.yml"), true), (url("gitlab/x"), true),
        ]
        for (target, writable) in cases {
            XCTAssertEqual(ProjectFileAccess.isWritable(target, root: root), writable, "\(writable ? "not writable" : "writable"): \(target.path)")
        }
    }

    func testReadGuard() {
        // `.git/side/` holds every track's conversation. Readable, it is a cross-track leak. Only
        // Side's own state is hidden — HEAD and refs are ordinary read targets.
        let cases: [(String, Bool)] = [
            (".git/side/think/index.json", false), (".GIT/side/think/index.json", false), (".git/Side/x", false),
            (".side/tracks.json", false), (".SIDE/tracks.json", false),
            (".git/HEAD", true), ("src/a.swift", true),
        ]
        for (path, readable) in cases {
            XCTAssertEqual(ProjectFileAccess.isReadable(url(path), root: root), readable, "\(readable ? "not readable" : "readable"): \(path)")
        }
    }
}
