import Foundation

/// Which other tracks are touching the same files as this one.
///
/// The problem this exists for: tracks are parallel lines of work, and an agent on one of them
/// has no idea the others exist. Two tracks quietly editing the same file is invisible until
/// promotion turns it into a merge conflict — at which point both changes are finished, both
/// look correct in isolation, and someone has to reconstruct which one was right.
///
/// Deliberately the *cheapest* form of cross-track awareness: pure git, no tokens, no model
/// involvement, shown to the human rather than told to the agent. That ordering was a design
/// call — awareness that costs context on every request has to earn it, and it can't earn it
/// before we know whether just showing the overlap is enough. Escalating to a system-prompt
/// summary or a dedicated tool stays available if this proves too passive.
public enum TrackOverlap {
    /// One other track that shares files with the track being examined.
    public struct Sibling: Equatable {
        public let branchName: String
        public let intent: String
        /// Only the paths *both* tracks changed, sorted — the whole point is the intersection.
        public let sharedPaths: [String]

        public init(branchName: String, intent: String, sharedPaths: [String]) {
            self.branchName = branchName
            self.intent = intent
            self.sharedPaths = sharedPaths
        }
    }

    /// Sibling overlaps, worst first, computed from each track's changed-file set.
    ///
    /// Pure on purpose: the git that produces those sets is slow, environmental, and awkward to
    /// test, while the question "who overlaps with whom, and how badly" is neither. Tracks with
    /// no shared paths are dropped rather than reported as empty rows.
    public static func siblings(
        of trackBranch: String,
        changedPathsByBranch: [String: Set<String>],
        intentsByBranch: [String: String]
    ) -> [Sibling] {
        guard let own = changedPathsByBranch[trackBranch], !own.isEmpty else { return [] }
        return changedPathsByBranch
            .filter { $0.key != trackBranch }
            .compactMap { branch, paths in
                let shared = own.intersection(paths)
                guard !shared.isEmpty else { return nil }
                return Sibling(
                    branchName: branch,
                    intent: intentsByBranch[branch] ?? "",
                    sharedPaths: shared.sorted()
                )
            }
            // Most-overlapping first; branch name breaks ties so the order is stable across
            // refreshes rather than following dictionary iteration.
            .sorted { ($0.sharedPaths.count, $1.branchName) > ($1.sharedPaths.count, $0.branchName) }
    }

    /// The banner's first line: *who* else is in these files. The paths themselves go on the
    /// second line (`sharedPathsSummary`) rather than into a tooltip — "3 files" without naming
    /// them tells you a conflict is coming without telling you whether you care, and the banner
    /// has the width to say it.
    public static func headline(for siblings: [Sibling]) -> String? {
        guard let first = siblings.first else { return nil }
        let label = first.intent.isEmpty ? first.branchName : first.intent
        if siblings.count == 1 {
            return "Also being changed by \u{201C}\(label)\u{201D}"
        }
        return "Also being changed by \u{201C}\(label)\u{201D} and \(siblings.count - 1) other track\(siblings.count == 2 ? "" : "s")"
    }

    /// The shared paths, as one line. Capped so a wide overlap can't turn the banner into a
    /// wall of text — past a handful, the count is the useful part anyway.
    public static func sharedPathsSummary(for siblings: [Sibling], limit: Int = 4) -> String {
        var seen: [String] = []
        for sibling in siblings {
            for path in sibling.sharedPaths where !seen.contains(path) { seen.append(path) }
        }
        guard seen.count > limit else { return seen.joined(separator: "  ·  ") }
        let shown = seen.prefix(limit).joined(separator: "  ·  ")
        return "\(shown)  ·  +\(seen.count - limit) more"
    }

    /// Every path a branch changed against its base, via `git diff --name-only`.
    ///
    /// Uses the three-dot form: `base...branch` diffs against their *merge base*, so work that
    /// landed on the base after this track started isn't misreported as this track's own
    /// changes — which is exactly the case a stacked track hits constantly.
    public static func changedPaths(branch: String, baseRef: String, cwd: String) -> Set<String> {
        let result = GitPaths.runGit(["diff", "--name-only", "\(baseRef)...\(branch)"], cwd: cwd)
        guard result.success else { return [] }
        return Set(result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }
}
