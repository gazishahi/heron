import Foundation

/// How risky a proposed shell command looks, from a quick pattern match against its text —
/// deliberately not a security boundary (a determined or obfuscated command can still slip
/// past this), just enough to put a visible warning on the approval card. Every command goes
/// through the same approval card either way.
///
/// **This must never gate auto-run.** See `CommandAutoRunPolicy` for that: a blacklist can't be
/// complete (an audit found `rm --recursive --force`, `git push origin +main`, `find . -delete`,
/// and `wget … | sh` all classifying as `.normal`), so auto-run is decided by an allowlist of
/// affirmatively read-only commands instead of by the absence of a match here.
public enum CommandRiskLevel: Equatable {
    case normal
    case destructive(reason: String)
}

public enum CommandRiskClassifier {
    /// Matched as a regular expression against the whole command string, case-insensitively
    /// unless `caseSensitive` is set. The first match wins and its reason is what the human
    /// sees — order roughly follows how commonly each pattern shows up in real destructive
    /// commands, not severity.
    private static let patterns: [(regex: String, reason: String, caseSensitive: Bool)] = [
        (#"rm\s+(-\w*r\w*f\w*|-\w*f\w*r\w*|.*--recursive|.*--force)"#, "Recursively or forcibly deletes files", false),
        (#"git\s+push\s+.*(--force(?!-with-lease)\b|(?<!\S)-f\b|\s\+\S)"#, "Force-pushes, which can overwrite remote history", false),
        (#"git\s+reset\s+--hard\b"#, "Discards uncommitted changes (git reset --hard)", false),
        (#"git\s+clean\s+.*-\w*[fd]"#, "Deletes untracked files (git clean)", false),
        // Case-sensitive on purpose: `-D` force-deletes even an unmerged branch, `-d` refuses to
        // — case-insensitive matching here would flag the safe, everyday flag as destructive.
        (#"git\s+branch\s+-D\b"#, "Force-deletes a branch, even if unmerged", true),
        (#"git\s+push\s+.*--delete\b"#, "Deletes a remote branch", false),
        (#"\bsudo\b"#, "Runs with elevated privileges", false),
        (#"\bchmod\s+.*-R\s+777\b"#, "Makes files world-writable, recursively", false),
        (#"\bchown\s+.*-R\b"#, "Recursively changes file ownership", false),
        (#"\bdd\s+if="#, "Low-level disk copy. Can overwrite an entire disk", false),
        (#"\bkill(all)?\s+-9\b"#, "Force-kills a process, skipping its own cleanup", false),
        // Any download piped into any shell, and process-substitution variants of the same trick.
        (#"\b(curl|wget|fetch)\b[^|]*\|\s*(sudo\s+)?\S*\b(sh|bash|zsh|fish|python\d?|ruby|perl|node)\b"#, "Pipes a downloaded script directly into an interpreter", false),
        (#"<\(\s*(curl|wget|fetch)\b"#, "Runs a downloaded script via process substitution", false),
        (#"\bfind\b.*\s(-delete|-exec\b|-execdir\b|-ok\b)"#, "Deletes or executes across matched files (find)", false),
        (#"\bxargs\b.*\b(rm|kill|mv|dd|truncate)\b"#, "Pipes results into a destructive command (xargs)", false),
        (#"\bdrop\s+(table|database)\b"#, "Drops a database or table", false),
        (#"\btruncate\s+table\b"#, "Empties a database table", false),
    ]

    public static func classify(_ command: String) -> CommandRiskLevel {
        for (pattern, reason, caseSensitive) in patterns {
            var options: String.CompareOptions = [.regularExpression]
            if !caseSensitive { options.insert(.caseInsensitive) }
            if command.range(of: pattern, options: options) != nil {
                return .destructive(reason: reason)
            }
        }
        return .normal
    }
}

/// Decides whether a command may skip its approval card when a track has `autoRunCommands` on.
///
/// Deliberately an **allowlist**: a command auto-runs only when we can affirmatively recognize
/// every part of it as read-only. Anything unrecognized — an unknown binary, a shell operator, a
/// flag that turns a reader into a writer — is not auto-runnable and goes to the human. That
/// inversion is the point: the previous "auto-run anything the destructive blacklist didn't
/// match" made an admittedly-incomplete heuristic into a consent boundary, so `rm --recursive
/// --force` could execute unattended.
public enum CommandAutoRunPolicy {
    /// Shell syntax that could chain, redirect, substitute, or background additional work. Their
    /// presence alone disqualifies a command — we only ever auto-run a single simple command.
    private static let disqualifyingSyntax = [
        ";", "&&", "||", "|", ">", "<", "`", "$(", "${", "&", "\n", "\r",
    ]

    /// Read-only commands, with the flags that would make each one write. A `nil` flag list means
    /// no flag makes it dangerous; matching is on the exact first token.
    private static let readOnlyCommands: [String: [String]] = [
        "ls": [], "pwd": [], "echo": [], "date": [], "whoami": [], "hostname": [],
        "cat": [], "head": [], "tail": [], "wc": [], "stat": [], "basename": [], "dirname": [],
        // `file -C` compiles a magic file, which writes one.
        "file": ["-C", "--compile"],
        // `env` and `printenv` are deliberately absent. `env` is a *launcher*: `env sh -c id`
        // or `env node evil.js` tokenizes as a clean read-only command with no forbidden flag,
        // and then execs its argument. It is the same class as awk/sed/node — a program that
        // takes another program as an ordinary argument — which the allowlist premise cannot
        // vouch for. `printenv` goes with it: it dumps every secret in the process environment
        // into a tool result. Found by the 2026-09-01 audit as a verified unattended-execution
        // path on any Guarded or Full track.
        "which": [], "type": [], "uname": [], "df": [], "du": [],
        "grep": [], "egrep": [], "fgrep": [],
        // Readers that *run a program* with one flag: ripgrep's preprocessor (`--pre sh` runs
        // `sh` on every file searched) and its hostname helper. Found by the 2026-09-30 audit as
        // unattended execution, the same class as `env`.
        "rg": ["--pre", "--pre-glob", "--hostname-bin"],
        // Readers that become writers, or runners, with one flag. `--compress-program` runs a
        // program for sort's temporary files.
        "sort": ["-o", "--output", "--compress-program"],
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
        "tree": ["-o"],
        "diff": [],
        // Deliberately absent, and they must stay absent: `awk`, `sed`, and `node` are
        // general-purpose interpreters whose *program text* is an ordinary argument, so no
        // flag list can make them read-only. `awk 'BEGIN{system("…")}'`, sed's `e` command,
        // and `node script.js` all execute arbitrary code while looking like a flagless read.
        // An audit found all three auto-running; the allowlist's premise is that we can
        // affirmatively recognize every part of a command as read-only, and for an
        // interpreter we simply cannot.
    ]

    /// Arguments that could reach outside the project. The executable allowlist says *what*
    /// runs; without this, nothing said *on what* — `cat ~/.aws/credentials`, `grep -r AKIA /`,
    /// and `find / -name id_rsa` were all auto-runnable, quietly undoing the containment
    /// `ProjectFileAccess` enforces so carefully one layer up. Conservative on purpose: a
    /// relative path inside the working directory is the only shape allowed, because the
    /// session's cwd can have been changed by the user or an earlier command, so even a
    /// relative path can't be resolved with confidence here.
    private static func argumentEscapesProject(_ argument: String) -> Bool {
        // Flags are not paths.
        guard !argument.hasPrefix("-") else { return false }
        if argument.hasPrefix("/") || argument.hasPrefix("~") { return true }
        let separated = "/" + argument + "/"
        return separated.contains("/../") || separated.contains("/./..")
    }

    /// Flags that make a read-only git subcommand write a file (`--output`) or run a configured
    /// program (external diff, textconv and filter drivers).
    private static let forbiddenGitFlags: [String] = ["--output", "--ext-diff", "--textconv", "--filters"]

    /// The only global options allowed before the subcommand. Every other one changes what
    /// runs or where: `-c key=value` sets any config (a pager, an external diff),
    /// `--exec-path=` moves where git finds its programs, `--git-dir`/`--work-tree` leave the
    /// project.
    private static let allowedGitGlobalOptions: Set<String> = ["--no-pager", "-P"]

    /// Read-only `git` subcommands. Everything else — push, reset, clean, checkout, commit,
    /// merge, rebase, branch, worktree — needs a human.
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "blame", "rev-parse", "describe",
        "ls-files", "ls-tree", "cat-file", "shortlog",
    ]

    /// `git config` is the one subcommand whose *write* form takes no flag at all
    /// (`git config user.email someone@example.com`), so it can't be handled by forbidding
    /// flags — it's only auto-runnable when it explicitly asks to read.
    private static let readingGitConfigFlags: Set<String> = [
        "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
    ]

    /// `projectRoot`, when given, lets the argument check resolve symlinks: `cat creds` is a
    /// read inside the project by its text and a read of `~/.aws/credentials` by its target. The
    /// textual rules are necessary but not sufficient — they see the string, not the filesystem.
    /// (2026-09-01 audit, command-execution Med.) Callers without a root get the textual rules only.
    public static func isAutoRunnable(_ command: String, projectRoot: URL? = nil) -> Bool {
        guard isTextuallyAutoRunnable(command) else { return false }
        guard let projectRoot else { return true }
        let tokens = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let resolvedRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        for argument in tokens.dropFirst() where !argument.hasPrefix("-") {
            let candidate = projectRoot.appendingPathComponent(argument)
            // Only things that exist can point somewhere; a missing path is refused by the
            // command itself, and a dangling link resolves to nothing readable.
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else { return false }
        }
        return true
    }

    private static func isTextuallyAutoRunnable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A blacklist hit is an immediate no even inside the allowlist path — belt and braces.
        if case .destructive = CommandRiskClassifier.classify(trimmed) { return false }
        for syntax in disqualifyingSyntax where trimmed.contains(syntax) { return false }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let executable = tokens.first else { return false }
        // No paths — an allowlisted *name* only, so `./rm` or `/tmp/evil/ls` can't impersonate one.
        guard !executable.contains("/") else { return false }
        let arguments = Array(tokens.dropFirst())

        if executable == "git" {
            // `git -C <path>` relocates the whole command, so git gets the same argument rule.
            if arguments.contains(where: argumentEscapesProject) { return false }
            guard let position = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else { return false }
            guard arguments[..<position].allSatisfy(allowedGitGlobalOptions.contains) else { return false }
            let subcommand = arguments[position]
            if subcommand == "config" {
                return arguments.contains { readingGitConfigFlags.contains($0) }
            }
            guard readOnlyGitSubcommands.contains(subcommand) else { return false }
            return !arguments.dropFirst(position + 1).contains { Self.matches($0, anyOf: forbiddenGitFlags) }
        }

        guard let forbiddenFlags = readOnlyCommands[executable] else { return false }
        if arguments.contains(where: argumentEscapesProject) { return false }
        return !arguments.contains { Self.matches($0, anyOf: forbiddenFlags) }
    }

    /// Whether an argument is one of the flags: exactly, with `=value`, or, for a one-letter
    /// flag, inside a cluster of them (`sort -uo out.txt` sets `-o` as surely as `-o` does).
    private static func matches(_ argument: String, anyOf flags: [String]) -> Bool {
        flags.contains { flag in
            if argument == flag || argument.hasPrefix(flag + "=") { return true }
            let isShort = flag.count == 2 && flag.hasPrefix("-") && !flag.hasPrefix("--")
            return isShort && argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.count > 2
                && argument.dropFirst().contains(flag.last!)
        }
    }
}
