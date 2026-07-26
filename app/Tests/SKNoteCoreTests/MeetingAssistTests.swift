import Foundation
import Testing
@testable import SKNoteCore

@Suite("Meeting assist — question detection")
struct MeetingAssistTests {

    @Test("a directed question from someone else fires")
    func directedQuestion() {
        #expect(MeetingAssist.isQuestionForMe(
            "How do I add you as a user in Stripe?", speakerIsMe: false, userName: "Usama"))
    }

    @Test("a question naming the user fires")
    func namedQuestion() {
        #expect(MeetingAssist.isQuestionForMe(
            "Usama, can you take the client call on Friday?", speakerIsMe: false, userName: "Usama Khan"))
    }

    @Test("a substantive question with no direct address still fires")
    func substantiveQuestion() {
        #expect(MeetingAssist.isQuestionForMe(
            "What is the timeline for the tax filing this quarter?", speakerIsMe: false, userName: nil))
    }

    @Test("the user's own speech never fires")
    func ownSpeechNever() {
        #expect(!MeetingAssist.isQuestionForMe(
            "How do I add you as a user in Stripe?", speakerIsMe: true, userName: "Usama"))
    }

    @Test("a non-question statement does not fire")
    func statementDoesNotFire() {
        #expect(!MeetingAssist.isQuestionForMe(
            "I will send the report tomorrow.", speakerIsMe: false, userName: "Usama"))
    }

    @Test("a tiny rhetorical question does not fire")
    func tinyRhetoricalDoesNotFire() {
        #expect(!MeetingAssist.isQuestionForMe("Right?", speakerIsMe: false, userName: "Usama"))
        #expect(!MeetingAssist.isQuestionForMe("Ok?", speakerIsMe: false, userName: nil))
    }
}
