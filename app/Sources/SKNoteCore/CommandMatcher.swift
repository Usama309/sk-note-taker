import Foundation

/// Ranking for the command palette's search. Pure and UI-free so it can be unit tested; the app
/// layer supplies titles/keywords and keeps the SwiftUI parts.
public enum CommandMatcher {

    /// How well a command matches the query, or nil when it does not match at all.
    /// Higher is better: prefix beats word-start beats substring beats keyword beats fuzzy, so
    /// typing "st" surfaces "Start Meeting" above a meeting that merely contains those letters.
    public static func score(title: String, keywords: [String], query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let title = title.lowercased()
        if title.hasPrefix(q) { return 1000 - title.count }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 800 - title.count }
        if title.contains(q) { return 600 - title.count }
        if keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 400 }
        if isSubsequence(q, of: title) { return 200 - title.count }
        return nil
    }

    /// Fuzzy match: every character of `needle` appears in `haystack`, in order.
    public static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var i = needle.startIndex
        for ch in haystack {
            if ch == needle[i] {
                i = needle.index(after: i)
                if i == needle.endIndex { return true }
            }
        }
        return false
    }
}
