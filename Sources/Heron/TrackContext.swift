import Foundation

/// What an agent may know about the *other* tracks in its project — structure, not conversation.
///
/// RFC R4 (2026-09-03): cross-track awareness is two read-only tools in the same project, never a
/// channel between agents. Dependency between tracks is expressed as a stacked track, not as a
/// message; there is no cross-project awareness, because it is rarely useful, costly in context,
/// and a privacy widening. Each track has its own worktree, so background agents never collide
/// on files — the overlap tool exists so an agent can *see* that two tracks are converging on the
/// same file before promotion turns it into a merge conflict.
public struct AgentTrackSummary: Equatable, Sendable {
    public let branchName: String
    public let intent: String
    /// `TrackStatus.rawValue`, kept as a string so this type has no dependency on the UI model.
    public let status: String
    /// The branch this track promotes into: the parent's branch for a stacked child, else the
    /// project's default branch.
    public let baseRef: String
    public let isCurrent: Bool
    /// Where `git diff` for this track runs — the shared checkout; every branch is visible there.
    public let gitDirectory: String

    public init(branchName: String, intent: String, status: String, baseRef: String, isCurrent: Bool, gitDirectory: String) {
        self.branchName = branchName
        self.intent = intent
        self.status = status
        self.baseRef = baseRef
        self.isCurrent = isCurrent
        self.gitDirectory = gitDirectory
    }
}

public enum TrackContextTools {
    /// The listing `list_tracks` returns. Changed-file counts come from git, one call per track,
    /// which is why this runs where the tool executor already runs: off the main thread.
    public static func listing(_ tracks: [AgentTrackSummary], changedPaths: (AgentTrackSummary) -> Set<String>) -> String {
        guard !tracks.isEmpty else { return "This project has no tracks." }
        return tracks.map { track in
            let count = changedPaths(track).count
            let marker = track.isCurrent ? "  ← this track" : ""
            let intent = track.intent.isEmpty ? "(no description)" : track.intent
            return "\(track.branchName) [\(track.status)] \(intent) · base \(track.baseRef) · \(count) changed file\(count == 1 ? "" : "s")\(marker)"
        }.joined(separator: "\n")
    }

    /// The report `read_track_overlap` returns for the current track.
    public static func overlapReport(current: AgentTrackSummary, all: [AgentTrackSummary], changedPaths: (AgentTrackSummary) -> Set<String>) -> String {
        var changedByBranch: [String: Set<String>] = [:]
        var intents: [String: String] = [:]
        for track in all {
            changedByBranch[track.branchName] = changedPaths(track)
            intents[track.branchName] = track.intent
        }
        let siblings = TrackOverlap.siblings(of: current.branchName, changedPathsByBranch: changedByBranch, intentsByBranch: intents)
        guard !siblings.isEmpty else {
            let own = changedByBranch[current.branchName]?.count ?? 0
            return own == 0
                ? "This track has no changes against \(current.baseRef) yet, so nothing can overlap."
                : "No other track in this project has changed any of the \(own) file\(own == 1 ? "" : "s") this track changed."
        }
        return siblings.map { sibling in
            let label = sibling.intent.isEmpty ? sibling.branchName : "\(sibling.intent) (\(sibling.branchName))"
            return "\(label) also changed:\n" + sibling.sharedPaths.map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
