import Foundation

public enum GitDiffMark { case added, modified, removedBefore }

public struct GitHunk {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }
}

public struct GitDiffResult {
    public let marks: [Int: GitDiffMark]
    public let hunks: [GitHunk]
    public let headContent: String?

    public init(marks: [Int: GitDiffMark], hunks: [GitHunk], headContent: String?) {
        self.marks = marks
        self.hunks = hunks
        self.headContent = headContent
    }
}

public enum GitDiffComputer {
    /// Spawns `git show`, so callers should fetch this once per tab (e.g. on open, and again
    /// after save) rather than on every debounced refresh — that's the expensive half of what
    /// used to be a two-subprocess round trip on every keystroke.
    public static func fetchHeadContent(projectRoot: URL, relativePath: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let raw = runGit(["show", "HEAD:\(relativePath)"], cwd: projectRoot.path)
            DispatchQueue.main.async { completion(raw.isEmpty ? nil : raw) }
        }
    }

    /// Diffs already-known HEAD content against the live buffer. No `git show` here — just the
    /// `--no-index` temp-file diff — so this stays cheap enough to call on every keystroke debounce.
    public static func diff(headContent: String?, currentContent: String, projectRoot: URL, completion: @escaping (GitDiffResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffResult(original: headContent, current: currentContent, projectRoot: projectRoot)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Unified diff *text* between two arbitrary strings, for review UI that shows the actual
    /// added/removed lines rather than the gutter's line-range marks. Same `--no-index`
    /// temp-file mechanism as `diffResult`, just with context lines and without hunk parsing —
    /// added for Heron's proposed-edit review, where the point is for a human to read the
    /// change before it touches disk.
    public static func unifiedDiffText(original: String, proposed: String, projectRoot: URL, contextLines: Int = 3) -> String {
        guard original != proposed else { return "" }
        let tmpDir = FileManager.default.temporaryDirectory
        let originalFile = tmpDir.appendingPathComponent("side-proposed-orig-\(UUID().uuidString).txt")
        let proposedFile = tmpDir.appendingPathComponent("side-proposed-new-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: originalFile)
            try? FileManager.default.removeItem(at: proposedFile)
        }
        do {
            try original.write(to: originalFile, atomically: true, encoding: .utf8)
            try proposed.write(to: proposedFile, atomically: true, encoding: .utf8)
        } catch { return "" }
        let output = runGit(["diff", "--no-index", "--no-color", "-U\(contextLines)", originalFile.path, proposedFile.path], cwd: projectRoot.path)
        // Drop git's file-header lines (diff --git, index, ---, +++) — they name temp files,
        // which would be noise at best and confusing at worst in a review pane.
        return output
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") && !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// A unified diff between two refs — `git diff <fromRef>...<toRef>` (triple-dot: against
    /// their merge-base, so a base branch that's moved on since the track forked doesn't pollute
    /// the diff with unrelated upstream changes). Used by Review to show a track's full change
    /// stream against its base, distinct from `unifiedDiffText`'s single-file string-vs-string
    /// comparison for a proposed edit.
    public static func refDiff(fromRef: String, toRef: String, cwd: String, contextLines: Int = 3) -> String {
        let output = runGit(["diff", "--no-color", "-U\(contextLines)", "\(fromRef)...\(toRef)"], cwd: cwd)
        return output.trimmingCharacters(in: .newlines)
    }

    private static func diffResult(original: String?, current: String, projectRoot: URL) -> GitDiffResult {
        guard let original else {
            guard !current.isEmpty else { return GitDiffResult(marks: [:], hunks: [], headContent: nil) }
            let lineCount = current.components(separatedBy: "\n").count
            var marks: [Int: GitDiffMark] = [:]
            for line in 1...max(lineCount, 1) { marks[line] = .added }
            let hunk = GitHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lineCount)
            return GitDiffResult(marks: marks, hunks: [hunk], headContent: nil)
        }
        guard original != current else { return GitDiffResult(marks: [:], hunks: [], headContent: original) }

        let tmpDir = FileManager.default.temporaryDirectory
        let originalFile = tmpDir.appendingPathComponent("side-diff-orig-\(UUID().uuidString).txt")
        let currentFile = tmpDir.appendingPathComponent("side-diff-cur-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: originalFile)
            try? FileManager.default.removeItem(at: currentFile)
        }
        do {
            try original.write(to: originalFile, atomically: true, encoding: .utf8)
            try current.write(to: currentFile, atomically: true, encoding: .utf8)
        } catch { return GitDiffResult(marks: [:], hunks: [], headContent: original) }

        let output = runGit(["diff", "--no-index", "--no-color", "-U0", originalFile.path, currentFile.path], cwd: projectRoot.path)
        let hunks = parseHunks(output)
        return GitDiffResult(marks: marks(for: hunks), hunks: hunks, headContent: original)
    }

    private static func marks(for hunks: [GitHunk]) -> [Int: GitDiffMark] {
        var marks: [Int: GitDiffMark] = [:]
        for hunk in hunks {
            if hunk.newCount == 0 {
                marks[max(hunk.newStart, 1)] = .removedBefore
            } else if hunk.oldCount == 0 {
                for line in hunk.newStart..<(hunk.newStart + hunk.newCount) { marks[line] = .added }
            } else {
                for line in hunk.newStart..<(hunk.newStart + hunk.newCount) { marks[line] = .modified }
            }
        }
        return marks
    }

    private static func parseHunks(_ diffOutput: String) -> [GitHunk] {
        var hunks: [GitHunk] = []
        guard let hunkRegex = try? NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@") else { return hunks }
        for line in diffOutput.components(separatedBy: "\n") where line.hasPrefix("@@") {
            let ns = line as NSString
            guard let match = hunkRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let oldStart = Int(group(1) ?? "0") ?? 0
            let oldCount = Int(group(2) ?? "1") ?? 1
            let newStart = Int(group(3) ?? "0") ?? 0
            let newCount = Int(group(4) ?? "1") ?? 1
            hunks.append(GitHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount))
        }
        return hunks
    }

    private static func runGit(_ args: [String], cwd: String) -> String {
        guard DeveloperTools.gitInstalled else { return "" }
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let exited = GitPaths.exitSignal(process)
        do { try process.run() } catch { return "" }
        // Read before waiting — waiting first deadlocks once git fills the pipe buffer
        // (see GitPaths.runGit).
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
