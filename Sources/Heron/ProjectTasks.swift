import Foundation

/// A project's known commands, as named things.
///
/// The problem this solves is that "the command that checks this project" had no noun. Verifying
/// work meant the model *guessing* a command string, and the user re-typing one they'd typed a
/// hundred times. A name fixes both ends: the agent asks for `test` rather than inventing
/// `swift test --parallel 2>&1 | tail`, and the human sees a button.
///
/// Deliberately not a new execution path. A task *is* a shell command, run through the same
/// `run_shell_command` machinery in the track's own visible terminal, under the same approval
/// rules. The only thing being added is the naming — which is exactly what makes the narrower
/// `run_task` tool safe to offer where arbitrary commands aren't: the model picks from a list
/// the project wrote, not a string it composed.
public struct ProjectTask: Equatable, Codable {
    public let name: String
    public let command: String
    /// What this task is for, in one clause — shown in the UI and given to the model, which
    /// otherwise has to infer intent from the command line.
    public let detail: String
    /// True for the task that answers "does this project still work?" — the one verification
    /// reaches for by default.
    public let isVerification: Bool

    public init(name: String, command: String, detail: String = "", isVerification: Bool = false) {
        self.name = name
        self.command = command
        self.detail = detail
        self.isVerification = isVerification
    }

    private enum CodingKeys: String, CodingKey { case name, command, detail, isVerification }

    /// Tolerant, like every persisted struct here: a hand-written `.side/tasks.json` with only
    /// `name` and `command` is the common case, and synthesized decoding refused it — which
    /// silently ignored the whole declaration and fell back to detection, with nothing to say why.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        isVerification = try container.decodeIfPresent(Bool.self, forKey: .isVerification) ?? false
    }
}

public enum ProjectTasks {
    /// A project can declare its own tasks here, overriding everything detected below. Kept
    /// beside the rules file, in the directory Side already owns.
    public static let declarationPath = ".side/tasks.json"

    /// The tasks for a project: declared ones if there are any, otherwise whatever the project's
    /// shape implies.
    ///
    /// Detection over configuration on purpose — a project that already says `swift test` in its
    /// Package.swift shouldn't have to say it again in a Side-specific file to get a Verify
    /// button. The declared file exists for the cases detection can't reach (a monorepo, an
    /// unusual runner, a build that needs flags).
    public static func tasks(projectRoot: URL) -> [ProjectTask] {
        if let declared = declaredTasks(projectRoot: projectRoot), !declared.isEmpty { return declared }
        return detectedTasks(projectRoot: projectRoot)
    }

    /// The task to run when something asks "verify this" without naming one: the task marked
    /// for it, else one called "test", else nothing. Never falls back to an arbitrary task —
    /// running `deploy` because it happened to be first would be a catastrophe with a plausible
    /// excuse.
    public static func verificationTask(projectRoot: URL) -> ProjectTask? {
        let all = tasks(projectRoot: projectRoot)
        return all.first { $0.isVerification } ?? all.first { $0.name == "test" }
    }

    public static func task(named name: String, projectRoot: URL) -> ProjectTask? {
        tasks(projectRoot: projectRoot).first { $0.name == name }
    }

    /// Declared tasks are honored only once the user has acknowledged the file — the same
    /// per-content consent `AGENTS.md` gets, for the same reason: it arrives with a cloned
    /// repository and it decides what `run_task` runs. Unacknowledged, it is simply not there
    /// and detection applies, so nothing from the file can execute before it has been seen.
    /// (2026-09-01 audit, prompt-injection Partial.)
    private static func declaredTasks(projectRoot: URL) -> [ProjectTask]? {
        let url = projectRoot.appendingPathComponent(declarationPath)
        guard let data = try? Data(contentsOf: url), let contents = String(data: data, encoding: .utf8) else { return nil }
        guard ProjectRules.isAcknowledged(url: url, contents: contents) else { return nil }
        return try? JSONDecoder().decode([ProjectTask].self, from: data)
    }

    /// The declaration file, if it exists and hasn't been acknowledged — what the UI must show the
    /// user before any of its commands can be run by name.
    public static func pendingDeclaration(projectRoot: URL) -> (url: URL, contents: String)? {
        let url = projectRoot.appendingPathComponent(declarationPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty else { return nil }
        return ProjectRules.isAcknowledged(url: url, contents: contents) ? nil : (url, contents)
    }

    // MARK: - Detection

    private static func detectedTasks(projectRoot: URL) -> [ProjectTask] {
        let fileManager = FileManager.default
        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: projectRoot.appendingPathComponent(relative).path)
        }

        var tasks: [ProjectTask] = []

        if exists("Package.swift") {
            tasks.append(ProjectTask(name: "build", command: "swift build", detail: "Compile the package"))
            tasks.append(ProjectTask(name: "test", command: "swift test", detail: "Run the package's tests", isVerification: true))
        }

        // An Xcode project's scheme isn't knowable without asking xcodebuild (which is slow and
        // can prompt), so the detected commands deliberately omit -scheme and let xcodebuild
        // pick the default. A project that needs a specific scheme declares its own tasks.
        if let xcodeproj = firstEntry(in: projectRoot, withExtension: "xcodeproj") {
            let flag = "-project \(shellQuoted(xcodeproj))"
            tasks.append(ProjectTask(name: "build", command: "xcodebuild \(flag) build", detail: "Build the Xcode project"))
            tasks.append(ProjectTask(name: "test", command: "xcodebuild \(flag) test", detail: "Run the Xcode project's tests", isVerification: true))
        }

        if let scripts = packageScripts(projectRoot: projectRoot) {
            let runner = exists("pnpm-lock.yaml") ? "pnpm" : (exists("yarn.lock") ? "yarn" : "npm run")
            for name in ["build", "test", "lint", "typecheck", "check", "dev", "start"] where scripts.contains(name) {
                tasks.append(ProjectTask(
                    name: name, command: "\(runner) \(name)",
                    detail: "package.json script \u{201C}\(name)\u{201D}",
                    isVerification: name == "test"
                ))
            }
        }

        if exists("Makefile"), let targets = makeTargets(projectRoot: projectRoot) {
            for name in ["build", "test", "check", "lint"] where targets.contains(name) {
                tasks.append(ProjectTask(
                    name: name, command: "make \(name)", detail: "Makefile target \u{201C}\(name)\u{201D}",
                    isVerification: name == "test" || name == "check"
                ))
            }
        }

        if exists("Cargo.toml") {
            tasks.append(ProjectTask(name: "build", command: "cargo build", detail: "Compile the crate"))
            tasks.append(ProjectTask(name: "test", command: "cargo test", detail: "Run the crate's tests", isVerification: true))
        }

        if exists("pyproject.toml") || exists("pytest.ini") || exists("tox.ini") {
            tasks.append(ProjectTask(name: "test", command: "pytest", detail: "Run the test suite", isVerification: true))
        }

        // First definition of a name wins — detection can legitimately fire twice (a Swift
        // package inside a repo that also has a Makefile), and two tasks called "test" would
        // make `task(named:)` ambiguous.
        var seen: Set<String> = []
        return tasks.filter { seen.insert($0.name).inserted }
    }

    private static func firstEntry(in root: URL, withExtension ext: String) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return contents.sorted().first { ($0 as NSString).pathExtension == ext }
    }

    private static func packageScripts(projectRoot: URL) -> Set<String>? {
        let url = projectRoot.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return nil }
        return Set(scripts.keys)
    }

    /// Target names from a Makefile, by the crude-but-sufficient rule: a line starting at column
    /// zero with `name:`. Pattern rules and `.PHONY` are skipped rather than parsed — this only
    /// needs to recognize the handful of conventional names above.
    private static func makeTargets(projectRoot: URL) -> Set<String>? {
        let url = projectRoot.appendingPathComponent("Makefile")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var targets: Set<String> = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(".") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" "), !name.contains("%"), !name.contains("=") else { continue }
            targets.insert(name)
        }
        return targets
    }

    private static func shellQuoted(_ value: String) -> String {
        value.contains(" ") ? "'\(value)'" : value
    }
}
