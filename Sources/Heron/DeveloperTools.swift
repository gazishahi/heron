import Foundation

/// Whether git can run. On a Mac without the Command Line Tools (or Xcode), `/usr/bin/git` is a
/// stub: running it fails and macOS puts up its install dialog, with no word from Side about why.
/// Every folder read as a non-repository (2026-09-30 audit, REL-2). Side checks first, without
/// running anything, and says what's missing instead.
public enum DeveloperTools {
    /// Checked on each call (a few file lookups, no process), so installing the tools while
    /// Side is open is noticed.
    public static var gitInstalled: Bool {
        gitInstalled(environment: ProcessInfo.processInfo.environment) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The developer directories `xcode-select -p` would choose between: `DEVELOPER_DIR`, the
    /// selected one, Xcode's, the Command Line Tools'. Git in any of them is enough.
    static func gitInstalled(environment: [String: String], isExecutable: (String) -> Bool) -> Bool {
        var directories: [String] = []
        if let set = environment["DEVELOPER_DIR"], !set.isEmpty { directories.append(set) }
        if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            directories.append(selected)
        }
        directories += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        return directories.contains { isExecutable(($0 as NSString).appendingPathComponent("usr/bin/git")) }
    }

    /// What Side says when git is missing.
    public static let missingMessage = "Git isn't installed on this Mac. Side uses the git in Apple's Command Line Tools."

    /// Opens macOS's installer for the Command Line Tools (its own dialog).
    public static func install() {
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
