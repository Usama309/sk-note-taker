import Foundation
import Testing
@testable import SKNoteCore

@Suite("Command palette matching")
struct CommandMatcherTests {

    @Test("a title prefix outranks a word-start, a substring, and a fuzzy hit")
    func rankingOrder() {
        let q = "sett"
        let exact = CommandMatcher.score(title: "Settings", keywords: [], query: q)
        let wordStart = CommandMatcher.score(title: "Replay Setup Guide", keywords: [], query: "setup")
        let fuzzy = CommandMatcher.score(title: "SELFTEST meeting", keywords: [], query: q)
        #expect(exact != nil && wordStart != nil && fuzzy != nil)
        #expect(exact! > wordStart!)
        #expect(wordStart! > fuzzy!)
    }

    @Test("typing part of a meeting title finds that meeting and not unrelated actions")
    func findsMeetingByTitle() {
        // The live bug this guards: "selft" must match the meeting, and must NOT match actions
        // that merely share some letters.
        #expect(CommandMatcher.score(title: "SELFTEST meeting", keywords: [], query: "selft") != nil)
        #expect(CommandMatcher.score(title: "Start Meeting", keywords: ["record"], query: "selft") == nil)
        #expect(CommandMatcher.score(title: "Open Assistant", keywords: ["ai"], query: "selft") == nil)
        #expect(CommandMatcher.score(title: "New Project", keywords: ["folder"], query: "selft") == nil)
    }

    @Test("keywords match when the title does not")
    func keywordMatch() {
        #expect(CommandMatcher.score(title: "Start Meeting", keywords: ["record"], query: "rec") != nil)
        #expect(CommandMatcher.score(title: "Start Meeting", keywords: ["record"], query: "zzz") == nil)
    }

    @Test("an empty query scores nothing (the caller shows its default list instead)")
    func emptyQuery() {
        #expect(CommandMatcher.score(title: "Settings", keywords: [], query: "") == nil)
        #expect(CommandMatcher.score(title: "Settings", keywords: [], query: "   ") == nil)
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(CommandMatcher.score(title: "SELFTEST meeting", keywords: [], query: "SELF") != nil)
        #expect(CommandMatcher.score(title: "Settings", keywords: [], query: "SeTtInGs") != nil)
    }

    @Test("subsequence requires order, and an empty needle is trivially contained")
    func subsequence() {
        #expect(CommandMatcher.isSubsequence("smt", of: "start meeting"))
        #expect(!CommandMatcher.isSubsequence("tsm", of: "start meeting"))
        #expect(CommandMatcher.isSubsequence("", of: "anything"))
        #expect(!CommandMatcher.isSubsequence("abc", of: "ab"))
    }

    @Test("shorter titles win among equal match kinds")
    func shorterTitlesWin() {
        let short = CommandMatcher.score(title: "Starred", keywords: [], query: "star")
        let long = CommandMatcher.score(title: "Starred Meetings Archive", keywords: [], query: "star")
        #expect(short! > long!)
    }
}
