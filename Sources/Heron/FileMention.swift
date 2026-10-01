import Foundation

/// `@path/to/file.swift` in a Think message — a *pointer*, never inlined content.
///
/// The tempting implementation is to paste the referenced file into the message. Don't: a
/// conversation that mentions six files would then carry six full copies in its persisted turns
/// *and* re-send all of them on every subsequent message, for the rest of the track's life. That
/// is precisely the unbounded-growth shape `AgentSessionStore` was restructured to kill, and it
/// would cost real money on every turn besides.
///
/// So a mention resolves to a path the model is told about, and the model reads it with the
/// `read_file` tool if it actually needs the contents. One extra round trip, bounded context.
public struct FileMention: Equatable {
    /// Exactly what the user typed after `@`, so an error message can quote them.
    public let raw: String
    /// Project-relative path, resolved against what's actually on disk.
    public let relativePath: String
    public let isDirectory: Bool
    /// `@path#L12-L40` — the lines the user pointed at (Make's inline instruct, Direction 02
    /// §5.3). Still a pointer: the model is told the range, never given the text.
    public let lines: ClosedRange<Int>?

    public init(raw: String, relativePath: String, isDirectory: Bool, lines: ClosedRange<Int>? = nil) {
        self.raw = raw
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.lines = lines
    }

    /// The pointer form Side writes for a range: `@path#L12-L40`, or `@path#L12` for one line.
    public static func pointer(relativePath: String, lines: ClosedRange<Int>) -> String {
        lines.count == 1 ? "@\(relativePath)#L\(lines.lowerBound)" : "@\(relativePath)#L\(lines.lowerBound)-L\(lines.upperBound)"
    }
}

public enum FileMentionResolver {
    /// Characters a mention can contain. Deliberately excludes `,` and `;` so
    /// "look at @a.swift, @b.swift" doesn't swallow punctuation into the path, and stops at
    /// whitespace so prose after a mention stays prose.
    private static let terminators = CharacterSet(charactersIn: " \t\n\r,;:!?)\u{201D}\"'")

    /// Pulls `@`-prefixed tokens out of message text.
    ///
    /// Skips an `@` that's part of a larger word (`user@example.com`, `@2x.png`) by requiring the
    /// preceding character to be whitespace or the start of the string — otherwise every email
    /// address in a message becomes a broken file reference.
    public static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let precedingIsBoundary: Bool
            if at == text.startIndex {
                precedingIsBoundary = true
            } else {
                let previous = text[text.index(before: at)]
                precedingIsBoundary = previous.isWhitespace || previous == "(" || previous == "\u{201C}"
            }
            let afterAt = text.index(after: at)
            index = afterAt
            guard precedingIsBoundary, afterAt < text.endIndex else { continue }
            let rest = text[afterAt...]
            let end = rest.rangeOfCharacter(from: terminators)?.lowerBound ?? rest.endIndex
            let token = String(rest[..<end])
            // A bare "@" is someone typing. A token with no name-shaped character in it ("@.",
            // "@-") is punctuation in prose, not a path — and this is the one place that rule
            // lives, so highlighting and resolution can't drift apart.
            if !token.isEmpty, token.rangeOfCharacter(from: .alphanumerics) != nil { tokens.append(token) }
            index = end
        }
        return tokens
    }

    /// Resolves tokens against the project. Unresolved tokens come back separately rather than
    /// being dropped: silently ignoring a typo'd path is how you get an agent confidently
    /// answering about a file nobody meant.
    public static func resolve(text: String, projectRoot: URL) -> (mentions: [FileMention], unresolved: [String]) {
        var mentions: [FileMention] = []
        var unresolved: [String] = []
        var seen = Set<String>()

        for token in mentionTokens(in: text) {
            // A trailing `#L12` / `#L12-L40` is a line range on the path, not part of it.
            var pathPart = Substring(token)
            var lines: ClosedRange<Int>?
            if let match = token.range(of: #"#L(\d+)(-L(\d+))?$"#, options: .regularExpression) {
                let spec = token[match].dropFirst(2)
                let bounds = spec.split(separator: "-").map { Int($0.drop(while: { $0 == "L" })) ?? 0 }
                if let first = bounds.first, first > 0 {
                    let last = max(first, bounds.count > 1 ? bounds[1] : first)
                    lines = first...last
                }
                pathPart = token[..<match.lowerBound]
            }
            let cleaned = pathPart.hasSuffix("/") ? String(pathPart.dropLast()) : String(pathPart)
            guard !cleaned.isEmpty else { continue }
            // Containment, not string trust: `@../../etc/passwd` must not resolve, and this is
            // the same rule `ProjectFileAccess` applies to tool arguments.
            //
            // `appendingPathComponent`, not `URL(fileURLWithPath:relativeTo:)`: the latter
            // produces a URL that keeps a *base*, and its `path` then reports only the relative
            // part — which silently defeated the prefix check below and made every valid mention
            // look out-of-project. Caught by these tests, not by reading.
            let candidate: URL = cleaned.hasPrefix("/")
                ? URL(fileURLWithPath: cleaned).standardizedFileURL
                : projectRoot.appendingPathComponent(cleaned).standardizedFileURL
            let rootPath = projectRoot.standardizedFileURL.path
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
                unresolved.append(token)
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                unresolved.append(token)
                continue
            }
            let relativePath = String(candidate.path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            guard seen.insert(relativePath + (lines.map { "#\($0)" } ?? "")).inserted else { continue }
            mentions.append(FileMention(raw: token, relativePath: relativePath, isDirectory: isDirectory.boolValue, lines: lines))
        }
        return (mentions, unresolved)
    }

    /// Ranges of every `@`-token in the text, for highlighting. Includes tokens that don't
    /// resolve to a real file: styling is about showing the user what Side *read as* a mention,
    /// so a typo should look like a mention and fail visibly rather than blend into prose.
    public static func tokenRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(of: "@", range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { break }
            searchStart = found.location + 1
            // Same boundary rule as `mentionTokens`, so highlighting can't disagree with what
            // actually gets sent.
            if found.location > 0 {
                let previous = ns.character(at: found.location - 1)
                guard let scalar = Unicode.Scalar(previous),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) || previous == unichar(UInt8(ascii: "(")) else { continue }
            }
            var end = found.location + 1
            while end < ns.length {
                guard let scalar = Unicode.Scalar(ns.character(at: end)),
                      !terminators.contains(scalar) else { break }
                end += 1
            }
            guard end > found.location + 1 else { continue }
            // A token has to contain something name-shaped: `@.` or `@-` in ordinary prose is
            // punctuation, and styling it as a file reference (as an early version did) makes
            // the highlighting look broken.
            let body = ns.substring(with: NSRange(location: found.location + 1, length: end - found.location - 1))
            guard body.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            ranges.append(NSRange(location: found.location, length: end - found.location))
        }
        return ranges
    }

    /// The note appended to a message that carries mentions — paths and nothing else.
    ///
    /// Says "read them if you need them" rather than "here they are," which is the whole design:
    /// the agent decides whether a mentioned file is worth a round trip, and a mention that turns
    /// out to be irrelevant costs nothing.
    public static func contextNote(mentions: [FileMention], unresolved: [String]) -> String? {
        guard !mentions.isEmpty || !unresolved.isEmpty else { return nil }
        var lines: [String] = []
        if !mentions.isEmpty {
            lines.append("The user referenced these project paths with @. Read the ones you need with read_file or list_files; their contents are not included here:")
            for mention in mentions {
                let range = mention.lines.map { $0.count == 1 ? " (line \($0.lowerBound))" : " (lines \($0.lowerBound)–\($0.upperBound))" } ?? ""
                lines.append("- \(mention.relativePath)\(mention.isDirectory ? "/ (directory)" : "")\(range)")
            }
        }
        if !unresolved.isEmpty {
            // Told plainly so the agent asks instead of inventing a plausible file.
            lines.append("These @ references don't exist in the project: \(unresolved.joined(separator: ", ")). Ask the user what they meant rather than guessing.")
        }
        return lines.joined(separator: "\n")
    }
}
