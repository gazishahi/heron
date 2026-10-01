import Foundation

/// The project's current compiler and linter complaints, in a form the agent can read.
///
/// This is the smallest piece of Phase 10 and probably the most valuable. Until now the agent
/// wrote code and had no way to learn whether it compiled — the loop closed only when the user
/// noticed and pasted an error back. Make has received LSP diagnostics per file all along;
/// nothing aggregated them, and nothing offered them to Heron. So an agent could introduce a
/// type error and confidently move on, and *did*.
///
/// Deliberately a read-only snapshot published by Make, not a query into the LSP layer. Heron
/// must not depend on Make's lifecycle (Think keeps working with no editor open, which is the
/// whole reason Heron exists as a separate engine), so the dependency points the safe way:
/// whoever has language servers running publishes what they know, and the tool reads whatever
/// is currently published.
public final class DiagnosticsSnapshot: @unchecked Sendable {
    public static let shared = DiagnosticsSnapshot()

    public struct Entry: Equatable {
        public let relativePath: String
        public let line: Int
        public let severity: String
        public let message: String
        public let source: String?

        public init(relativePath: String, line: Int, severity: String, message: String, source: String?) {
            self.relativePath = relativePath
            self.line = line
            self.severity = severity
            self.message = message
            self.source = source
        }
    }

    private let lock = NSLock()
    private var entriesByRoot: [String: [String: [Entry]]] = [:]

    /// Replaces everything known about one file. LSP publishes per file, and an empty array is
    /// meaningful — it's how a server says "this file is clean now."
    public func publish(_ entries: [Entry], forFile relativePath: String, projectRoot: URL) {
        let key = projectRoot.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        var forRoot = entriesByRoot[key] ?? [:]
        if entries.isEmpty {
            forRoot.removeValue(forKey: relativePath)
        } else {
            forRoot[relativePath] = entries
        }
        entriesByRoot[key] = forRoot
    }

    public func clear(projectRoot: URL) {
        lock.lock()
        defer { lock.unlock() }
        entriesByRoot.removeValue(forKey: projectRoot.standardizedFileURL.path)
    }

    /// Everything currently known, errors first, then by path and line.
    public func entries(projectRoot: URL) -> [Entry] {
        let key = projectRoot.standardizedFileURL.path
        lock.lock()
        let forRoot = entriesByRoot[key] ?? [:]
        lock.unlock()
        return forRoot.values.flatMap { $0 }.sorted { left, right in
            if left.severity != right.severity { return left.severity == "error" }
            if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
            return left.line < right.line
        }
    }

    /// The tool's rendering. Bounded, because a project mid-refactor can have thousands of
    /// diagnostics and the model pays for every one of them — and the first twenty errors are
    /// what matter anyway; the rest are usually the same cause repeated.
    public static let maxReported = 40

    public func report(projectRoot: URL, errorsOnly: Bool) -> String {
        var all = entries(projectRoot: projectRoot)
        if errorsOnly { all = all.filter { $0.severity == "error" } }
        guard !all.isEmpty else {
            return errorsOnly
                ? "No errors reported. (Language servers only report on files that have been opened, so this is not the same as a clean build. Run the project's build or test task to be sure.)"
                : "No diagnostics reported. (Language servers only report on files that have been opened, so this is not the same as a clean build. Run the project's build or test task to be sure.)"
        }
        let shown = all.prefix(Self.maxReported).map { entry in
            let origin = entry.source.map { " [\($0)]" } ?? ""
            return "\(entry.relativePath):\(entry.line): \(entry.severity): \(entry.message)\(origin)"
        }.joined(separator: "\n")
        guard all.count > Self.maxReported else { return shown }
        return shown + "\n… and \(all.count - Self.maxReported) more."
    }

    public init() {}
}
