import Foundation

/// Turns an approved `ProposedEdit` into an actual change. The only place in Heron that can
/// modify the project, and it is only ever reached from an explicit human Apply — that's the
/// invariant the whole propose/approve design rests on.
public struct ProposedEditApplier {
    /// Applies into Make's open tab when the file is open (returns true), so undo/save/dirty
    /// tracking all behave as if the user typed it. Nil-safe: when Make isn't hosting the file,
    /// the applier writes to disk instead.
    public let applyIntoOpenTab: (URL, String) -> Bool
    /// Current on-disk-or-buffer content for staleness checking, same source the proposal was
    /// computed against.
    public let currentContent: (URL) -> String?

    public func apply(_ edit: ProposedEdit) -> ProposedEditOutcome {
        // Between proposal and approval the user may have typed, saved, switched branches, or
        // had a formatter run. Applying a full-file replacement computed against different
        // content would silently destroy whatever happened in between, so refuse instead.
        let existing = currentContent(edit.url)
        if edit.isNewFile {
            if existing != nil { return .staleBase }
        } else {
            guard let existing else { return .staleBase }
            guard existing == edit.baseContent else { return .staleBase }
        }

        // Disk first, always — including when the file is open in Make.
        //
        // This used to hand the content to the open tab and stop there, leaving the tab merely
        // *dirty* with no autosave behind it. Disk still held the old content, so the checkpoint
        // that follows staged and committed the old bytes: a checkpoint, and a "✓ Checkpoint"
        // line, for a commit that did not contain the change. Closing the tab with "Don't Save"
        // then discarded the edit entirely while Review went on claiming it had happened.
        // Approving an edit is a decision, so it lands like a save.
        do {
            try FileManager.default.createDirectory(at: edit.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TextFileCodec.write(edit.proposedContent, to: edit.url)
        } catch {
            return .writeFailed(error.localizedDescription)
        }
        // Then sync the open buffer, if any, so the editor shows what's now on disk.
        _ = applyIntoOpenTab(edit.url, edit.proposedContent)
        return .applied
    }

    public init(applyIntoOpenTab: @escaping (URL, String) -> Bool, currentContent: @escaping (URL) -> String?) {
        self.applyIntoOpenTab = applyIntoOpenTab
        self.currentContent = currentContent
    }
}
