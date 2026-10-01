import Foundation

/// A file change an agent has asked for but that has **not** touched disk. This type is the
/// mechanism behind the constitution's "agents propose; people promote": an `edit_file` or
/// `write_file` tool call produces one of these and stops. Nothing is written until a human
/// approves it, and rejecting one leaves the project byte-identical.
public struct ProposedEdit: Identifiable {
    public let id: UUID
    public let toolUseId: String
    public let url: URL
    public let relativePath: String
    /// What the agent's change was computed against — the live unsaved buffer when the file is
    /// open and dirty in Make, otherwise disk. Proposing against stale disk content while the
    /// user has unsaved edits would silently discard those edits on apply. `var`, not `let` — see
    /// `stripContent()`: these two fields are the entire reason a resolved proposal used to keep
    /// a full duplicate copy of a file (old *and* new) alive in `AgentRunner.entries` forever.
    public var baseContent: String
    public var proposedContent: String
    /// True when the file doesn't exist yet, so the UI can say "create" rather than "edit".
    public let isNewFile: Bool
    /// Computed once, from the real content, at construction time — so it survives
    /// `stripContent()` clearing `baseContent`/`proposedContent` out from under it later.
    public let addedLineCount: Int

    public init(toolUseId: String, url: URL, relativePath: String, baseContent: String, proposedContent: String, isNewFile: Bool) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.url = url
        self.relativePath = relativePath
        self.baseContent = baseContent
        self.proposedContent = proposedContent
        self.isNewFile = isNewFile
        self.addedLineCount = proposedContent.components(separatedBy: "\n").count - baseContent.components(separatedBy: "\n").count
    }

    /// Called once a proposal is resolved and its `diffText` has already been computed —
    /// `AgentRunner.entries` keeps every resolved proposal around for the life of the session
    /// purely to redraw an already-decided card on reattach, which only ever needs
    /// `relativePath`/`isNewFile`/`addedLineCount`/the separately-stored diff text again, never
    /// the raw file content. Dropping it here is what keeps a long Think session's memory
    /// bounded to "diffs shown," not "every file version ever proposed, twice."
    public mutating func stripContent() {
        baseContent = ""
        proposedContent = ""
    }
}

public enum ProposedEditOutcome {
    case applied
    case rejected
    /// The file changed underneath the proposal between it being made and approved — applying
    /// would clobber whatever happened in between, so the user is told instead.
    case staleBase
    case writeFailed(String)

    /// What gets fed back to the model as the tool result, so its next turn reflects reality
    /// rather than assuming the edit landed.
    public var toolResultText: String {
        switch self {
        // "(unsaved)" was true when applying only touched the open buffer. It stopped being
        // true once the applier started writing to disk first — and a live test caught the
        // agent faithfully relaying the stale claim to the user, telling them to save a file
        // that was already saved.
        case .applied: return "Applied. The user approved this edit and it is written to disk."
        case .rejected: return "Rejected by the user. The file is unchanged. Ask what they'd prefer instead of retrying the same edit."
        case .staleBase: return "Not applied: the file changed after this edit was proposed. Re-read the file and propose again."
        case .writeFailed(let message): return "Not applied. Writing failed: \(message)"
        }
    }

    public var isError: Bool {
        switch self {
        case .applied, .rejected: return false
        case .staleBase, .writeFailed: return true
        }
    }
}
