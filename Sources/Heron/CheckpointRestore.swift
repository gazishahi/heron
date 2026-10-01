import Foundation

/// Undoing agent work, without ever destroying anything.
///
/// The obvious implementation — `git reset --hard <sha>` — is the wrong one for Side, for three
/// independent reasons, each of which alone would rule it out:
///
/// 1. **It throws away uncommitted work.** A track's worktree routinely holds edits the user made
///    by hand between agent runs. Those aren't in any checkpoint (checkpoints only ever contain
///    what the agent changed), so a hard reset silently deletes work the user never agreed to
///    lose. "Undo the agent's last change" must never mean "and also your own."
/// 2. **It contradicts what a checkpoint *is*.** The constitution calls checkpoints a durable
///    record of what an agent did. A reset erases that record from history — the audit trail is
///    gone precisely when someone is most likely to want it (after something went wrong).
/// 3. **It breaks promotion.** A track's checkpoints can already have been merged into a parent
///    track or main. Rewriting this branch's history after that produces divergence the user
///    can't see and didn't ask for.
///
/// So undoing is *forward* motion: a new commit that reverses the old one, exactly like `git
/// revert`. History grows, nothing is lost, the audit trail records both the change and its
/// undo — and an undo can itself be undone. The one thing a revert can't claim is that the tree
/// is byte-identical to some past moment; that's the honest trade, and it's the right one.
public enum CheckpointRestore {
    /// What to reverse.
    public enum Scope: Equatable {
        /// Just this checkpoint — later ones stay. Surgical, and the common case: "that one
        /// change was wrong, the rest were fine."
        case single
        /// This checkpoint and everything after it, reversed newest-first so each revert applies
        /// against the tree the next one expects.
        case throughLatest
    }

    public enum Outcome: Equatable {
        case reverted(commitSHA: String, checkpointCount: Int)
        /// The reverse doesn't apply cleanly — the files moved on since. Nothing was changed;
        /// git's conflict state is rolled back before returning, so the worktree is untouched.
        case conflicted(paths: [String])
        case nothingToDo
        case failed(String)
        /// The person has changes staged. An undo is a commit, and staging is how git decides
        /// what a commit holds, so it would either take their staged work into the undo or, when
        /// the undo fails, have to unstage it. Neither is acceptable; nothing is done until they
        /// commit or unstage. (2026-09-30 audit, C2: a failed undo reset staged files to HEAD.)
        case stagedChanges(paths: [String])
    }

    /// Commits to reverse, newest-first — the order `git revert` needs, since each reversal is
    /// computed against the tree the *later* commits produced.
    ///
    /// Pure so the ordering rule is testable without a repository: get this wrong and a
    /// multi-checkpoint undo conflicts with itself for reasons that look like git being flaky.
    public static func commitsToRevert(
        checkpoints: [Checkpoint], target: Checkpoint, scope: Scope
    ) -> [String] {
        let ordered = checkpoints
            .filter { $0.gitCommitSHA != nil }
            .sorted { $0.createdAt < $1.createdAt }
        switch scope {
        case .single:
            return target.gitCommitSHA.map { [$0] } ?? []
        case .throughLatest:
            guard let index = ordered.firstIndex(where: { $0.id == target.id }) else { return [] }
            return ordered[index...].compactMap(\.gitCommitSHA).reversed()
        }
    }

    /// The message on the undo commit. Names what was undone, because six months later the
    /// commit log is the only thing left that remembers.
    public static func revertMessage(target: Checkpoint, scope: Scope, count: Int) -> String {
        let intent = target.declaredIntent.isEmpty ? "an agent checkpoint" : "\u{201C}\(target.declaredIntent)\u{201D}"
        switch scope {
        case .single:
            return "Undo agent checkpoint: \(intent)"
        case .throughLatest:
            return count <= 1
                ? "Undo agent checkpoint: \(intent)"
                : "Undo \(count) agent checkpoints back to \(intent)"
        }
    }

    /// Applies the reversal in `worktreePath` as a single new commit.
    ///
    /// `--no-commit` for every revert, then one commit at the end: reversing four checkpoints
    /// should read as one deliberate undo in the log, not four mechanical entries. On any
    /// failure the whole thing is abandoned (`git revert --quit` plus a checkout of the paths
    /// git touched), so a conflict leaves the worktree exactly as it was rather than half-undone
    /// with conflict markers in it.
    @discardableResult
    public static func perform(
        commits: [String], message: String, worktreePath: String,
        runGit: (([String], String) -> (success: Bool, output: String)) = { args, cwd in GitPaths.runGit(args, cwd: cwd) }
    ) -> Outcome {
        guard !commits.isEmpty else { return .nothingToDo }
        let staged = runGit(["diff", "--cached", "--name-only"], worktreePath)
        guard staged.success else { return .failed(staged.output) }
        let stagedPaths = staged.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard stagedPaths.isEmpty else { return .stagedChanges(paths: stagedPaths) }
        // What the reversal may touch: the checkpoints' own files, and nothing else.
        let checkpointPaths = Set(commits.flatMap { sha in
            runGit(["show", "--name-only", "--format=", sha], worktreePath).output
                .split(separator: "\n").map(String.init)
        })

        for sha in commits {
            let result = runGit(["revert", "--no-commit", "--no-edit", sha], worktreePath)
            guard !result.success else { continue }
            // Conflicted (or otherwise refused): unwind and report which files disagreed.
            let conflicted = runGit(["diff", "--name-only", "--diff-filter=U"], worktreePath)
                .output.split(separator: "\n").map(String.init)
            abandon(worktreePath: worktreePath, limitedTo: checkpointPaths, runGit: runGit)
            return conflicted.isEmpty ? .failed(result.output) : .conflicted(paths: conflicted)
        }

        let commit = runGit(["commit", "-m", message], worktreePath)
        guard commit.success else {
            abandon(worktreePath: worktreePath, limitedTo: checkpointPaths, runGit: runGit)
            return .failed(commit.output)
        }
        let sha = runGit(["rev-parse", "HEAD"], worktreePath).output
        return .reverted(commitSHA: sha, checkpointCount: commits.count)
    }

    /// Puts the worktree back the way it was after a failed revert, touching **only** what the
    /// revert itself wrote.
    ///
    /// This used to run `git reset --hard HEAD`, which was the exact mistake this file's opening
    /// comment warns about: a hard reset also discards the user's own uncommitted edits, so a
    /// conflicted undo destroyed work that had nothing to do with the checkpoint. Found by an
    /// audit; the original test missed it because the worktree happened to be clean at the
    /// moment of the conflict.
    ///
    /// `revert --quit` clears the sequencer state but leaves the half-applied changes in the
    /// tree, so they have to be undone explicitly — per path, from the pre-revert HEAD snapshot,
    /// which is precisely the set of files the revert touched and nothing else.
    ///
    /// The index was empty of the person's changes when the undo began (see `.stagedChanges`), so
    /// what's staged now is the revert's; it's still limited to the checkpoints' own files, so a
    /// path the person had nothing staged in but changed meanwhile can't be swept in.
    private static func abandon(
        worktreePath: String, limitedTo checkpointPaths: Set<String>,
        runGit: (([String], String) -> (success: Bool, output: String))
    ) {
        // Everything the revert wrote: conflicted paths plus anything it staged cleanly before
        // hitting the conflict.
        let conflicted = runGit(["diff", "--name-only", "--diff-filter=U"], worktreePath)
            .output.split(separator: "\n").map(String.init)
        let staged = runGit(["diff", "--name-only", "--cached"], worktreePath)
            .output.split(separator: "\n").map(String.init)
        _ = runGit(["revert", "--quit"], worktreePath)
        let touched = Set(conflicted + staged).filter { !$0.isEmpty }.intersection(checkpointPaths)
        guard !touched.isEmpty else { return }
        // `reset` unstages them, `checkout` restores their content — both scoped to these paths,
        // so a modified file the user never mentioned is never even read.
        _ = runGit(["reset", "-q", "HEAD", "--"] + touched.sorted(), worktreePath)
        _ = runGit(["checkout", "HEAD", "--"] + touched.sorted(), worktreePath)
    }
}
