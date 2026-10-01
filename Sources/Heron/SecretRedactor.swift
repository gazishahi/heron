import Foundation

/// Strips credential-shaped strings out of tool output before it goes anywhere durable.
///
/// Every tool result was persisted verbatim into the track's session file and replayed to the
/// model on every subsequent turn. One `cat .env`, one `env`, one stack trace with a connection
/// string, and the secret lives on disk in plaintext forever *and* is re-sent on every message
/// for the rest of that conversation. Redacting at capture is what makes both of those stop
/// being true at once.
///
/// Two things this deliberately is not. It isn't a security boundary: pattern matching can't
/// catch a secret that doesn't look like one, and nothing here protects a user who pastes a key
/// into the composer themselves. And it isn't an attempt to hide the file's contents from the
/// user — the terminal still shows what it showed; this only governs what's stored and re-sent.
public enum SecretRedactor {
    public static let placeholder = "[redacted]"

    /// Ordered because the first match wins on overlapping text: specific token shapes before
    /// the generic `KEY=value` catch-all, so a recognizable token keeps its own label.
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let sources: [(String, String)] = [
            // PEM private keys — the whole block, not just the header.
            ("private key", "-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z ]*PRIVATE KEY-----"),
            // Provider keys with distinctive prefixes.
            ("api key", "\\bsk-[A-Za-z0-9_-]{16,}"),
            ("api key", "\\bsk_(?:live|test)_[A-Za-z0-9]{16,}"),
            ("github token", "\\bgh[pousr]_[A-Za-z0-9]{20,}"),
            ("slack token", "\\bxox[abprs]-[A-Za-z0-9-]{10,}"),
            ("google api key", "\\bAIza[A-Za-z0-9_-]{20,}"),
            ("aws access key id", "\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b"),
            // JWTs: three base64url segments, and the header always starts `eyJ`.
            ("token", "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"),
            // `Authorization: Bearer …` — keep the scheme, drop the credential.
            ("credential", "(?i)(authorization\\s*:\\s*(bearer|basic)\\s+)[A-Za-z0-9._~+/=-]{8,}"),
            // A URL carrying inline credentials: scheme://user:secret@host.
            ("url credential", "(?i)\\b([a-z][a-z0-9+.-]*://[^\\s:/@]+:)[^\\s@]{3,}(?=@)"),
            // The generic shape: an assignment whose *name* says it's a secret. Covers
            // `.env` files, `env` output, and YAML/JSON config alike.
            ("secret", "(?i)\\b([A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIALS?)[A-Z0-9_]*\\s*[:=]\\s*)[\"']?([^\\s\"',]{6,})[\"']?"),
        ]
        return sources.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    /// Returns the text with anything credential-shaped replaced, plus whether anything changed
    /// (so a caller can tell the user why the stored output differs from what they saw).
    public static func redacting(_ text: String) -> (text: String, didRedact: Bool) {
        var result = text
        var didRedact = false
        for (name, regex) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            // Where a pattern captures a group, group 1 is always the *prefix to keep* (the
            // variable name, the `Bearer` scheme) so the shape of the line stays readable.
            // Alternations inside a pattern must therefore be non-capturing — a live run caught
            // `sk_(live|test)_` writing its own alternative back out as `STRIPE_KEY=live[…]`.
            let template = regex.numberOfCaptureGroups >= 1 ? "$1[redacted \(name)]" : "[redacted \(name)]"
            let replaced = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            if replaced != result {
                didRedact = true
                result = replaced
            }
        }
        return (result, didRedact)
    }

    public static func redacted(_ text: String) -> String { redacting(text).text }
}
