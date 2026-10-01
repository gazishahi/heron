import Foundation

public enum FuzzyMatcher {
    /// Subsequence-based fuzzy score (fzf-style): all query characters must appear in
    /// order in the candidate. Higher is better. Returns nil if the query doesn't match.
    public static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let queryChars = Array(query.lowercased())
        let candidateChars = Array(candidate)
        let candidateLower = Array(candidate.lowercased())

        var qi = 0
        var score = 0
        var consecutiveRun = 0
        var previousMatchIndex = -1

        for ci in 0..<candidateChars.count {
            guard qi < queryChars.count else { break }
            guard candidateLower[ci] == queryChars[qi] else { continue }

            var charScore = 1
            if previousMatchIndex == ci - 1 {
                consecutiveRun += 1
                charScore += consecutiveRun * 3
            } else {
                consecutiveRun = 0
            }

            if ci == 0 {
                charScore += 5
            } else {
                let prev = candidateChars[ci - 1]
                if prev == "/" || prev == "_" || prev == "-" || prev == "." {
                    charScore += 5
                } else if candidateChars[ci].isUppercase && !prev.isUppercase {
                    charScore += 3
                }
            }

            score += charScore
            previousMatchIndex = ci
            qi += 1
        }

        guard qi == queryChars.count else { return nil }
        // Mild preference for shorter/denser matches over long paths that happen to contain the subsequence.
        score -= candidateChars.count / 20
        return score
    }
}
