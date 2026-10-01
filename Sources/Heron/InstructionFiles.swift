import Foundation

/// The files that give agents standing instructions, and who reads each one (Library,
/// `SIDE_RFC_LIBRARY.md`). Heron's own lookup is `ProjectRules`; the outside agents' are their
/// documented conventions, which they apply themselves, with or without Side's acknowledgement.
public struct InstructionFile: Equatable, Sendable {
    public enum Scope: String, Sendable { case project, user }

    /// How Heron treats this file, for the files Heron looks for at all.
    public enum HeronUse: Equatable, Sendable {
        /// The file Heron folds into its system prompt, once acknowledged.
        case inUse(acknowledged: Bool)
        /// Present, but an earlier file in Heron's search order wins.
        case shadowed(by: String)
        /// Heron would read it if it existed.
        case candidate
    }

    public let url: URL
    public let scope: Scope
    /// The path as the user would say it: "AGENTS.md", "~/.claude/CLAUDE.md".
    public let displayPath: String
    /// The outside agents that read this file on their own.
    public let readers: [String]
    public let heron: HeronUse?
    public let exists: Bool
}

public enum InstructionFiles {
    /// Project files outside agents read, by relative path. Heron's (`ProjectRules.candidateNames`)
    /// are merged in by `discover`.
    static let projectReaders: [(path: String, readers: [String])] = [
        ("SIDE.md", []),
        (".side/rules.md", []),
        ("AGENTS.md", ["Codex", "Pi", "other agents that read AGENTS.md"]),
        ("CLAUDE.md", ["Claude Code"]),
        (".claude/CLAUDE.md", ["Claude Code"]),
        ("CLAUDE.local.md", ["Claude Code"]),
        ("GEMINI.md", ["Gemini CLI"]),
    ]

    static let userReaders: [(path: String, readers: [String])] = [
        (".claude/CLAUDE.md", ["Claude Code"]),
        (".codex/AGENTS.md", ["Codex"]),
        (".gemini/GEMINI.md", ["Gemini CLI"]),
        (".pi/agent/AGENTS.md", ["Pi"]),
    ]

    /// Every instruction file for a working copy and the user, present or not, project first.
    public static func discover(workingRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstructionFile] {
        let heronOrder = ProjectRules.candidateNames
        let heronInUse = heronOrder.first { hasContent(workingRoot.appendingPathComponent($0)) }
        var files: [InstructionFile] = projectReaders.map { entry in
            let url = workingRoot.appendingPathComponent(entry.path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            var heron: InstructionFile.HeronUse?
            if heronOrder.contains(entry.path) {
                if entry.path == heronInUse {
                    let contents = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    heron = .inUse(acknowledged: ProjectRules.isAcknowledged(url: url, contents: contents))
                } else if exists, let winner = heronInUse {
                    heron = .shadowed(by: winner)
                } else {
                    heron = .candidate
                }
            }
            return InstructionFile(url: url, scope: .project, displayPath: entry.path, readers: entry.readers, heron: heron, exists: exists)
        }
        files += userReaders.map { entry in
            let url = home.appendingPathComponent(entry.path)
            return InstructionFile(url: url, scope: .user, displayPath: "~/" + entry.path, readers: entry.readers, heron: nil,
                                   exists: FileManager.default.fileExists(atPath: url.path))
        }
        return files
    }

    /// Everyone who reads the file, Heron first when it does.
    public static func readerNames(_ file: InstructionFile) -> [String] {
        (file.heron == nil ? [] : ["Heron"]) + file.readers
    }

    private static func hasContent(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
