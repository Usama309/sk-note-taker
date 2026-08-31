import Testing
@testable import SKNoteCore

@Suite("Diarization live-pass cadence")
struct DiarizationCadenceTests {
    @Test("short meetings retain responsive 15-second speaker updates")
    func shortMeetingCadence() {
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 0) == 15)
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 119) == 15)
    }

    @Test("long meetings progressively reduce full-history work")
    func longMeetingCadence() {
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 120) == 60)
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 599) == 60)
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 600) == 180)
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 2_400) == 180)
    }

    @Test("a deliberately slower configured interval is preserved")
    func customCadenceIsNeverShortened() {
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 60,
                                                       baseInterval: 240) == 240)
        #expect(DiarizationService.liveRefreshInterval(totalSeconds: 1_200,
                                                       baseInterval: 240) == 240)
    }
}
