import Foundation

/// A skill on disk: a folder with a `SKILL.md` whose front matter names and describes it
/// (Library step 3, `SIDE_RFC_LIBRARY.md`). Listed, not loaded: Heron doesn't use skills (L3);
/// the agents that do find them on their own.
public struct SkillEntry: Equatable, Sendable {
    public let name: String
    public let description: String
    /// The `SKILL.md`.
    public let url: URL
    public let scope: InstructionFile.Scope
    /// Where it was found, as the user would say it: "~/.claude/skills".
    public let location: String
    public let readers: [String]
    /// Other places the same skill appears, through a symlink ("~/.claude/skills" linking into
    /// "~/.agents/skills" is how installers share one copy).
    public let alsoIn: [String]
}

public enum SkillCatalog {
    static let projectLocations: [(path: String, readers: [String])] = [
        (".claude/skills", ["Claude Code"]),
        (".agents/skills", ["Codex", "other agents that read .agents/skills"]),
    ]

    static let userLocations: [(path: String, readers: [String])] = [
        (".claude/skills", ["Claude Code"]),
        (".agents/skills", ["Codex", "other agents that read .agents/skills"]),
        (".codex/skills", ["Codex"]),
    ]

    /// Every skill for a working copy and the user, project first, then by name. A skill
    /// reached from several places (symlinks) is listed once, where it really lives, with every
    /// agent that reaches it.
    public static func discover(workingRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SkillEntry] {
        let project = projectLocations.flatMap { found(in: workingRoot.appendingPathComponent($0.path), scope: .project, location: $0.path, readers: $0.readers) }
        let user = userLocations.flatMap { found(in: home.appendingPathComponent($0.path), scope: .user, location: "~/" + $0.path, readers: $0.readers) }
        var order: [String] = []
        var groups: [String: [Found]] = [:]
        for item in project + user {
            if groups[item.realPath] == nil { order.append(item.realPath) }
            groups[item.realPath, default: []].append(item)
        }
        let merged: [SkillEntry] = order.compactMap { key in
            guard let group = groups[key], let primary = group.first(where: { !$0.isLink }) ?? group.first else { return nil }
            var readers: [String] = []
            for reader in group.flatMap(\.entry.readers) where !readers.contains(reader) { readers.append(reader) }
            let e = primary.entry
            return SkillEntry(name: e.name, description: e.description, url: e.url, scope: group.contains { $0.entry.scope == .project } ? .project : .user,
                              location: e.location, readers: readers, alsoIn: group.filter { $0.entry.location != e.location }.map(\.entry.location))
        }
        return merged.filter { $0.scope == .project }.sorted { $0.name < $1.name } + merged.filter { $0.scope == .user }.sorted { $0.name < $1.name }
    }

    private struct Found {
        let entry: SkillEntry
        let realPath: String
        let isLink: Bool
    }

    private static func found(in directory: URL, scope: InstructionFile.Scope, location: String, readers: [String]) -> [Found] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let fields = frontMatter(text)
            let isLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let entry = SkillEntry(name: fields["name"] ?? folder.lastPathComponent, description: fields["description"] ?? "",
                                   url: file, scope: scope, location: location, readers: readers, alsoIn: [])
            return Found(entry: entry, realPath: file.resolvingSymlinksInPath().path, isLink: isLink)
        }
    }

    /// The simple YAML a `SKILL.md` opens with: `key: value` lines, quoted or not, and folded
    /// (`>`) or literal (`|`) blocks of indented lines.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") {
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty,
                      lines[index].trimmingCharacters(in: .whitespaces) != "---" {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: value.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }
}
