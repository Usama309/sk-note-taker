import Foundation
import Testing
@testable import SKNoteCore

@Suite("Meeting Codable back-compat")
struct MeetingCodableTests {
    @Test("a meeting.json missing the new hasScreenRecording key still decodes")
    func decodesWithoutScreenRecordingKey() throws {
        let m = Meeting(title: "Old meeting", hasRecording: true, durationSec: 12)
        let data = try JSONEncoder().encode(m)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "hasScreenRecording")   // simulate an older saved file
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(Meeting.self, from: stripped)
        #expect(decoded.title == "Old meeting")
        #expect(decoded.hasScreenRecording == nil)
        #expect(decoded.recordedScreen == false)
    }

    @Test("a saved screen recording round-trips")
    func screenRecordingRoundTrips() throws {
        let m = Meeting(title: "With screen", hasScreenRecording: true)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        #expect(decoded.recordedScreen == true)
    }
}
