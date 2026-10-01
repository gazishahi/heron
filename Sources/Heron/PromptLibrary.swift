import Foundation

/// A prompt someone would otherwise retype (Library, `SIDE_RFC_LIBRARY.md`). One Markdown file
/// each: the file name is the slash name, an optional `# Title` first line names it for people,
/// and the rest is what Think inserts. It never sends on its own (L2), which is why a project's
/// prompts, arriving with a cloned repo, need no acknowledgement: the user reads the text in the
/// composer before it does anything.
public struct SavedPrompt: Equatable, Sendable {
    public enum Scope: String, Sendable {
        /// The user's own, in Application Support.
        case user
        /// The project's, in `.side/prompts/`, shared through the repo.
        case project
    }

    /// The slash name: the file name without `.md`.
    public let name: String
    public let title: String
    public let body: String
    public let url: URL
    public let scope: Scope
    /// A template: "Start Track" creates a track named by the title and sends the body as its
    /// first message (front matter `track: true`).
    public let startsTrack: Bool
}

public enum PromptLibrary {
    /// Where the user's own prompts live. Tests point it somewhere private.
    public nonisolated(unsafe) static var userDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Side/Prompts")
    }()

    public static let projectDirectoryName = ".side/prompts"

    public static func projectDirectory(root: URL) -> URL { root.appendingPathComponent(projectDirectoryName) }

    /// Every prompt, sorted by name. On a name both define, the project's wins: it's the more
    /// specific one, and the team shares it.
    public static func all(projectRoot: URL?) -> [SavedPrompt] {
        var byName: [String: SavedPrompt] = [:]
        for prompt in load(userDirectory, scope: .user) { byName[prompt.name] = prompt }
        if let projectRoot {
            for prompt in load(projectDirectory(root: projectRoot), scope: .project) { byName[prompt.name] = prompt }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public static func prompt(named name: String, projectRoot: URL?) -> SavedPrompt? {
        all(projectRoot: projectRoot).first { $0.name == name }
    }

    /// Writes a prompt, replacing `replacing` when its name or scope changed.
    @discardableResult
    public static func save(title: String, body: String, scope: SavedPrompt.Scope, projectRoot: URL?, startsTrack: Bool = false, replacing: SavedPrompt? = nil) throws -> SavedPrompt {
        let directory: URL
        switch scope {
        case .user: directory = userDirectory
        case .project:
            guard let projectRoot else { throw CocoaError(.fileNoSuchFile) }
            directory = projectDirectory(root: projectRoot)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = slug(cleanTitle)
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".md")
        let text = (startsTrack ? "---\ntrack: true\n---\n" : "") + "# \(cleanTitle)\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let replacing, replacing.url.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: replacing.url)
        }
        return parse(text, url: url, scope: scope)
    }

    public static func delete(_ prompt: SavedPrompt) throws {
        try FileManager.default.removeItem(at: prompt.url)
    }

    /// "Review for Concurrency Bugs" → "review-for-concurrency-bugs".
    public static func slug(_ title: String) -> String {
        var result = ""
        var pendingDash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.append(character)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return String(result.prefix(64))
    }

    static func parse(_ text: String, url: URL, scope: SavedPrompt.Scope) -> SavedPrompt {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        var lines = text.components(separatedBy: "\n")
        let fields = SkillCatalog.frontMatter(text)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        var title = name
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let startsTrack = ["true", "yes"].contains(fields["track"]?.lowercased() ?? "")
        return SavedPrompt(name: name, title: title, body: body, url: url, scope: scope, startsTrack: startsTrack)
    }

    private static func load(_ directory: URL, scope: SavedPrompt.Scope) -> [SavedPrompt] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text, url: url, scope: scope)
        }
    }
}
