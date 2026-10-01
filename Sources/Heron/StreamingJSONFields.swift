import Foundation

/// Reads string fields out of a JSON object that **hasn't finished arriving yet**.
///
/// Providers stream a tool call's arguments as a sequence of `input_json_delta` fragments, and
/// until the last one lands the accumulated text is not valid JSON — so `JSONSerialization`
/// refuses all of it. That is why Side used to show nothing at all while the model wrote a file:
/// the path was known within the first few tokens, and the whole card waited on the last one.
///
/// This is deliberately *not* a JSON parser. It answers exactly one question — "what do the
/// string values for these keys look like so far?" — and gives up quietly the moment the text
/// stops making sense, because being wrong here would mean showing the user a preview of an edit
/// that isn't the edit about to be proposed. Everything that *acts* still goes through real
/// parsing (`AgentRunner.parseArguments`) on the complete text.
///
/// Only top-level string values are extracted; nested objects, arrays, and non-string scalars are
/// skipped over so a later key is still reachable. No edit tool takes a nested argument, and if
/// one ever does, "skipped" is the right failure.
public enum StreamingJSONFields {

    /// What the fragment received so far reveals.
    public struct Partial: Equatable {
        /// Decoded value so far, per requested key. A key present here with `complete` not
        /// containing it is a value still being written — safe to display, never to act on.
        public var values: [String: String] = [:]
        /// Keys whose closing quote has arrived, so their value will not change again.
        public var complete: Set<String> = []

        public func value(for key: String) -> String? { values[key] }
        public func completedValue(for key: String) -> String? { complete.contains(key) ? values[key] : nil }

        public init(values: [String: String] = [:], complete: Set<String> = []) {
            self.values = values
            self.complete = complete
        }
    }

    public static func extract(_ text: String, keys: Set<String>) -> Partial {
        var partial = Partial()
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func skipWhitespace() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "\n" || scalars[index] == "\r" || scalars[index] == "\t" {
                index += 1
            }
        }

        skipWhitespace()
        guard index < scalars.count, scalars[index] == "{" else { return partial }
        index += 1

        while true {
            skipWhitespace()
            guard index < scalars.count else { return partial }
            if scalars[index] == "," { index += 1; continue }
            if scalars[index] == "}" { return partial }
            guard scalars[index] == "\"" else { return partial }

            let key = readString(scalars, from: &index)
            // An unterminated *key* tells us nothing — we don't yet know which field it is.
            guard key.isTerminated else { return partial }
            skipWhitespace()
            guard index < scalars.count, scalars[index] == ":" else { return partial }
            index += 1
            skipWhitespace()
            guard index < scalars.count else { return partial }

            switch scalars[index] {
            case "\"":
                let value = readString(scalars, from: &index)
                if keys.contains(key.text) {
                    partial.values[key.text] = value.text
                    if value.isTerminated { partial.complete.insert(key.text) }
                }
                guard value.isTerminated else { return partial }
            case "{", "[":
                guard skipContainer(scalars, from: &index) else { return partial }
            default:
                // A number, `true`, `false`, or `null` — nothing this needs, but it has to be
                // stepped over or the keys after it become unreachable.
                while index < scalars.count, scalars[index] != "," && scalars[index] != "}" { index += 1 }
                guard index < scalars.count else { return partial }
            }
        }
    }

    // MARK: - Scanning

    private struct ScannedString {
        public let text: String
        /// False when the fragment ran out before the closing quote — the normal case for the
        /// value currently being streamed.
        public let isTerminated: Bool
    }

    /// Reads a JSON string starting at an opening quote, decoding escapes. On an incomplete
    /// escape sequence at the very end of the fragment (`…\` or `…\u12`) the partial escape is
    /// dropped rather than guessed: one missing character is invisible, a wrong one is a lie.
    private static func readString(_ scalars: [Unicode.Scalar], from index: inout Int) -> ScannedString {
        index += 1  // opening quote
        var out = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                index += 1
                return ScannedString(text: String(out), isTerminated: true)
            }
            guard scalar == "\\" else {
                out.append(scalar)
                index += 1
                continue
            }
            guard index + 1 < scalars.count else {
                index = scalars.count
                return ScannedString(text: String(out), isTerminated: false)
            }
            let escape = scalars[index + 1]
            index += 2
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append(Unicode.Scalar(8)!)
            case "f": out.append(Unicode.Scalar(12)!)
            case "\"", "\\", "/": out.append(escape)
            case "u":
                guard index + 3 < scalars.count else {
                    index = scalars.count
                    return ScannedString(text: String(out), isTerminated: false)
                }
                let hex = String(String.UnicodeScalarView(scalars[index..<(index + 4)]))
                index += 4
                guard let code = UInt32(hex, radix: 16) else { break }
                // A lone high surrogate needs its pair, which may not have arrived yet.
                if (0xD800...0xDBFF).contains(code) {
                    guard index + 5 < scalars.count,
                          scalars[index] == "\\", scalars[index + 1] == "u",
                          let low = UInt32(String(String.UnicodeScalarView(scalars[(index + 2)..<(index + 6)])), radix: 16),
                          (0xDC00...0xDFFF).contains(low)
                    else {
                        // Either malformed or still in flight; either way, emit nothing for it.
                        if index + 5 >= scalars.count {
                            index = scalars.count
                            return ScannedString(text: String(out), isTerminated: false)
                        }
                        break
                    }
                    index += 6
                    let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    if let value = Unicode.Scalar(combined) { out.append(value) }
                } else if let value = Unicode.Scalar(code) {
                    out.append(value)
                }
            default:
                break  // Not a JSON escape; dropping it beats inventing a character.
            }
        }
        return ScannedString(text: String(out), isTerminated: false)
    }

    /// Steps over a balanced `{…}` or `[…]`, respecting strings and their escapes. Returns false
    /// if the container never closes within the fragment.
    private static func skipContainer(_ scalars: [Unicode.Scalar], from index: inout Int) -> Bool {
        var depth = 0
        while index < scalars.count {
            switch scalars[index] {
            case "{", "[":
                depth += 1
                index += 1
            case "}", "]":
                depth -= 1
                index += 1
                if depth == 0 { return true }
            case "\"":
                let scanned = readString(scalars, from: &index)
                if !scanned.isTerminated { return false }
            default:
                index += 1
            }
        }
        return false
    }
}
