import Foundation

/// Project-wide text search — one implementation behind the agent's `search_files` tool and the
/// human's Find in Project. They were never meant to differ: the agent had this for weeks while
/// the person sitting at the keyboard had nothing, which the 2026-09-01 audit called the largest
/// missing capability not on the v1 non-goals list.
///
/// Reads the live buffer for a file that is open and dirty in Make, disk otherwise, so a match
/// reflects what the user sees rather than what was last saved — same rule the tool always had.
public enum ProjectTextSearch {
    public struct Match: Equatable {
        public let url: URL
        public let relativePath: String
        /// 1-based, as editors and `path:line` links count.
        public let line: Int
        public let text: String

        public init(url: URL, relativePath: String, line: Int, text: String) {
            self.url = url
            self.relativePath = relativePath
            self.line = line
            self.text = text
        }
    }

    public struct Options {
        public var isRegex = false
        /// Restricts to one file extension, compared case-insensitively without the dot.
        public var fileExtension: String? = nil
        public var limit = 100

        public init(isRegex: Bool = false, fileExtension: String? = nil, limit: Int = 100) {
            self.isRegex = isRegex
            self.fileExtension = fileExtension
            self.limit = limit
        }
    }

    public enum Failure: Error, LocalizedError {
        case invalidRegex(String)
        public var errorDescription: String? {
            if case .invalidRegex(let detail) = self { return "Invalid regular expression: \(detail)" }
            return nil
        }
    }

    public struct Results {
        public let matches: [Match]
        /// True when `limit` stopped the search — there were more.
        public let truncated: Bool

        public init(matches: [Match], truncated: Bool) {
            self.matches = matches
            self.truncated = truncated
        }
    }

    public static func search(root: URL, query: String, options: Options = Options(), liveBuffer: (URL) -> String? = { _ in nil }) throws -> Results {
        guard !query.isEmpty else { return Results(matches: [], truncated: false) }
        var regex: NSRegularExpression?
        if options.isRegex {
            do { regex = try NSRegularExpression(pattern: query, options: [.caseInsensitive]) }
            catch { throw Failure.invalidRegex(error.localizedDescription) }
        }
        let wantedExtension = options.fileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))

        var matches: [Match] = []
        for file in ProjectFileAccess.scan(root: root) {
            if let wantedExtension, !wantedExtension.isEmpty,
               (file.relativePath as NSString).pathExtension.lowercased() != wantedExtension { continue }
            guard let text = liveBuffer(file.url) ?? loadText(file.url) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                } else {
                    matched = line.range(of: query, options: .caseInsensitive) != nil
                }
                guard matched else { continue }
                if matches.count >= options.limit { return Results(matches: matches, truncated: true) }
                matches.append(Match(url: file.url, relativePath: file.relativePath, line: index + 1, text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return Results(matches: matches, truncated: false)
    }

    private static func loadText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= ProjectFileAccess.maxReadableFileSize else { return nil }
        return ProjectFileAccess.decodeText(from: data)
    }
}
