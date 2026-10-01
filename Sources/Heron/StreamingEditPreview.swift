import Foundation

/// Decides what a proposed edit's card should show *while the model is still writing it*.
///
/// Before this, an edit tool call was invisible until its last token: the transcript showed a
/// spinner, then a finished diff appeared all at once. The path is usually known within the first
/// few tokens of the call, and on a large file the content takes seconds — so the user spent those
/// seconds with no idea which file was about to change, which is the one fact that decides whether
/// they're going to care.
///
/// What is shown is deliberately *not* a diff. A real diff needs a `git diff --no-index`
/// subprocess per computation, which is nowhere near affordable per token, and half-written
/// content diffed against the file on disk would render as "the whole file was deleted and
/// replaced" — technically what the fragment says, and completely misleading. So the preview shows
/// the text being written, and the real diff replaces it once the call completes and the executor
/// has validated it. No decision is offered until then.
public enum StreamingEditPreview {

    public struct Draft: Equatable {
        /// The `path` argument, only ever surfaced once its closing quote has arrived — a
        /// half-written path could name a different file than the one being edited.
        public let path: String
        /// The text the model is writing: the whole file for `write_file`, the replacement text
        /// for `edit_file`.
        public let body: String
        /// Every field the eventual proposal needs has arrived. The preview stops updating here;
        /// the executor takes over.
        public let isComplete: Bool

        public init(path: String, body: String, isComplete: Bool) {
            self.path = path
            self.body = body
            self.isComplete = isComplete
        }
    }

    /// `nil` when there is nothing worth showing yet — an unsupported tool, or a call whose path
    /// hasn't finished arriving.
    public static func draft(toolName: String, partialJSON: String) -> Draft? {
        let bodyKey: String
        let requiredKeys: Set<String>
        switch toolName {
        case "write_file":
            bodyKey = "content"
            requiredKeys = ["path", "content"]
        case "edit_file":
            // `old_string` is required for the proposal but never shown: it's the text being
            // replaced, which is already on screen in the file. `new_string` is the news.
            bodyKey = "new_string"
            requiredKeys = ["path", "old_string", "new_string"]
        default:
            return nil
        }
        let partial = StreamingJSONFields.extract(partialJSON, keys: requiredKeys)
        guard let path = partial.completedValue(for: "path"), !path.isEmpty else { return nil }
        return Draft(
            path: path,
            body: partial.value(for: bodyKey) ?? "",
            isComplete: requiredKeys.isSubset(of: partial.complete)
        )
    }

    /// The preview body rendered in the shape `UnifiedDiff.parseHunks` expects, so the same
    /// renderer draws it as draws the real diff that replaces it.
    ///
    /// A new file's lines are marked `+` — that genuinely is what the change is. An existing
    /// file's are left unmarked, and so render as context: what is arriving is the new text, but
    /// which of those lines are actually *changes* is not knowable until the whole content is
    /// here and can be diffed properly. Tinting them green before then would be a guess.
    public static func previewDiffText(body: String, isNewFile: Bool) -> String {
        let lines = body.components(separatedBy: "\n")
        let header = "@@ -0,0 +1,\(lines.count) @@"
        guard isNewFile else { return ([header] + lines.map { " " + $0 }).joined(separator: "\n") }
        return ([header] + lines.map { "+" + $0 }).joined(separator: "\n")
    }
}
