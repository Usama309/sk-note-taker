import Foundation

public enum MeetingAssist {
    /// Whether a just-completed utterance looks like a question aimed at the user, so the assistant
    /// can proactively draft an answer. Conservative: never fires on the user's own speech, always
    /// requires a question mark, and then wants either a directed signal ("you"/"your"/the user's
    /// name) or a substantive question (five or more words), so small rhetorical asides are skipped.
    public static func isQuestionForMe(_ text: String, speakerIsMe: Bool, userName: String?) -> Bool {
        guard !speakerIsMe else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("?"), t.count >= 6 else { return false }
        let lower = t.lowercased()
        let wordCount = lower.split { !$0.isLetter }.filter { !$0.isEmpty }.count
        let firstName = userName?
            .split(separator: " ").first
            .map(String.init)?
            .lowercased()
        let directed = lower.contains("you") || lower.contains("your")
            || (firstName.map { $0.count >= 2 && lower.contains($0) } ?? false)
        return directed || wordCount >= 5
    }
}
