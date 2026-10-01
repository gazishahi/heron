import Foundation

/// How full a track's context window is, and when to say something about it.
///
/// A long Think conversation fails in a specific, confusing way: every turn is replayed on every
/// send, so the request grows until the provider rejects it outright — and the user's only
/// evidence is a message that suddenly stops working. This makes the approach visible before
/// that, and `AgentRunner.compact` gives it somewhere to go.
public enum ContextBudget {
    /// Rough characters-per-token for English prose and code. Real tokenizers disagree with this
    /// by a few percent in both directions, which is fine for a gauge — but *not* fine as the
    /// only input, which is why `usage(...)` prefers the provider's own reported count when it
    /// has one. Never used to decide whether a request is legal, only how full the bar looks.
    public static let charactersPerToken = 4.0

    /// The share of the window at which the UI starts warning, and at which it insists.
    public static let warningFraction = 0.7
    public static let criticalFraction = 0.9
    /// A send past this share compacts first, with Undo (SIDE_RFC_HERON_EFFICIENCY.md, Q2).
    public static let autoCompactFraction = 0.85

    public enum Status: Equatable {
        case comfortable
        /// Worth mentioning, not worth interrupting for.
        case approaching
        /// Close enough that the next few turns could fail; compaction is the actual fix.
        case critical

        public var shouldSuggestCompaction: Bool { self != .comfortable }
    }

    /// A whole-conversation estimate. Tool results dominate — a single `read_file` can be tens of
    /// thousands of characters — so this counts them like everything else rather than pretending
    /// only the prose matters.
    public static func estimatedTokens(in turns: [AgentTurn]) -> Int {
        var characters = 0
        for turn in turns {
            for block in turn.content {
                switch block {
                case .text(let text):
                    characters += text.count
                case .toolResult(_, let content, _):
                    characters += content.count
                case .toolUse(_, let name, let input):
                    characters += name.count + String(describing: input).count
                case .image:
                    // The API prices images by pixels, not bytes; a downscaled screenshot runs
                    // roughly 1,500 tokens. A flat figure keeps the gauge honest enough.
                    characters += 6_000
                }
            }
        }
        return Int(Double(characters) / charactersPerToken)
    }

    /// What the next request will roughly cost, against the model's window.
    ///
    /// `lastReportedInputTokens` is the provider's own count for the previous request and is
    /// preferred when present: it's measured rather than guessed, and the next request is this
    /// conversation plus a little. The estimate still acts as a floor, so turns added *since*
    /// that request (a big tool result, say) aren't invisible.
    public static func usage(
        turns: [AgentTurn], windowTokens: Int, lastReportedInputTokens: Int?
    ) -> (usedTokens: Int, windowTokens: Int, fraction: Double, status: Status) {
        let estimate = estimatedTokens(in: turns)
        let used = max(estimate, lastReportedInputTokens ?? 0)
        guard windowTokens > 0 else { return (used, windowTokens, 0, .comfortable) }
        let fraction = min(Double(used) / Double(windowTokens), 1)
        let status: Status
        switch fraction {
        case criticalFraction...: status = .critical
        case warningFraction...: status = .approaching
        default: status = .comfortable
        }
        return (used, windowTokens, fraction, status)
    }

    /// The instruction used to summarize a conversation before replacing it.
    ///
    /// Written to preserve the things a continuation actually needs — decisions, file paths, the
    /// state of unfinished work — and to say plainly that detail will be lost, because a summary
    /// that pretends to be lossless is how an agent ends up confidently wrong about what it did.
    public static let compactionInstruction = """
        Summarize this conversation so it can continue in a fresh context window. Write it for \
        yourself, not for the user.

        Include: what the user is trying to accomplish; decisions made and the reasons; exact \
        paths of files read or changed; commands run and what they showed; anything still \
        unfinished or waiting on a decision; and any correction the user made to your earlier \
        approach.

        Leave out: full file contents (you can re-read them), and anything already superseded. \
        Be specific: a path or a function name is worth more than a sentence about it. Do not \
        address the user or ask questions; this text replaces the conversation. Reply with the \
        summary as text, without calling a tool.
        """

    /// Wraps a model-written summary so the next turn can tell what it is.
    static let summaryMarker = "[Earlier conversation, compacted to fit the context window."

    public static func summaryTurnText(_ summary: String) -> String {
        """
        \(summaryMarker) Detail beyond this summary \
        is gone. Re-read files or ask rather than assuming.]

        \(summary)
        """
    }
}
