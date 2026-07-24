import Foundation
import Testing
@testable import SKNoteCore

@Suite("Zoom AX interpret")
struct ZoomAXInterpretTests {

    // A tree mirroring the real solo, self-muted dump the user captured
    // (~/Desktop/SK Note Taker Logs/zoom-ax-tree.txt): one participant, muted, no active speaker.
    private func soloTree() -> AXNode {
        AXNode(role: "AXApplication", title: "zoom.us", children: [
            AXNode(role: "AXWindow", title: "Zoom Meeting", children: [
                AXNode(role: "AXTabGroup", desc: "Muhammad Usama, Computer audio muted", children: [
                    AXNode(role: "AXImage"),
                    AXNode(role: "AXButton", desc: "View Muhammad Usama's profile"),
                ]),
                AXNode(role: "AXScrollArea", children: [
                    AXNode(role: "AXOutline", desc: "Participants list", children: [
                        AXNode(role: "AXRow", subrole: "AXTableRow", children: [
                            AXNode(role: "AXCell", children: [
                                AXNode(role: "AXStaticText", value: "Muhammad Usama (Host, me)"),
                                AXNode(role: "AXMenuButton", desc: "More options for Muhammad Usama, collapsed"),
                                AXNode(role: "AXButton", desc: "Start video"),
                                AXNode(role: "AXButton", desc: "Unmute"),
                            ]),
                        ]),
                    ]),
                ]),
                AXNode(role: "AXUnknown", desc: "Participants (1)", children: [
                    AXNode(role: "AXStaticText", value: "Participants (1)"),
                ]),
            ]),
        ])
    }

    // A synthetic 2-person call: the host (me, unmuted) and Alice, with Zoom marking Alice as the
    // active speaker on her video tile.
    private func twoPersonTalking() -> AXNode {
        AXNode(role: "AXApplication", title: "zoom.us", children: [
            AXNode(role: "AXWindow", title: "Zoom Meeting", children: [
                AXNode(role: "AXOutline", desc: "Participants list", children: [
                    AXNode(role: "AXRow", children: [AXNode(role: "AXCell", children: [
                        AXNode(role: "AXStaticText", value: "Muhammad Usama (Host, me)"),
                        AXNode(role: "AXButton", desc: "Mute"),
                        AXNode(role: "AXButton", desc: "Stop video"),
                    ])]),
                    AXNode(role: "AXRow", children: [AXNode(role: "AXCell", children: [
                        AXNode(role: "AXStaticText", value: "Alice Smith"),
                        AXNode(role: "AXButton", desc: "Unmute"),
                    ])]),
                ]),
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXImage", desc: "Alice Smith, active speaker"),
                ]),
                AXNode(role: "AXUnknown", desc: "Participants (2)"),
            ]),
        ])
    }

    // MARK: Name cleaning

    @Test("cleanName strips (Host, me) and comma tags")
    func cleaning() {
        #expect(ZoomAX.cleanName("Muhammad Usama (Host, me)") == "Muhammad Usama")
        #expect(ZoomAX.cleanName("Alice Smith, active speaker") == "Alice Smith")
        #expect(ZoomAX.cleanName("Muhammad Usama, Computer audio muted") == "Muhammad Usama")
        #expect(ZoomAX.cleanName("  Bob Lee  ") == "Bob Lee")
        #expect(ZoomAX.cleanName("Zoom") == nil)           // stoplisted UI word
        #expect(ZoomAX.cleanName("") == nil)
    }

    @Test("names parse from profile and more-options descriptions")
    func namePatterns() {
        #expect(ZoomAX.nameFromProfile("View Muhammad Usama's profile") == "Muhammad Usama")
        #expect(ZoomAX.nameFromProfile("Something else") == nil)
        #expect(ZoomAX.nameFromMoreOptions("More options for Alice Smith, collapsed") == "Alice Smith")
    }

    // MARK: Roster

    @Test("roster reads the real solo dump as one participant")
    func rosterSolo() {
        #expect(ZoomAX.roster(in: soloTree()) == ["Muhammad Usama"])
    }

    @Test("roster reads both participants in a 2-person call")
    func rosterTwo() {
        #expect(ZoomAX.roster(in: twoPersonTalking()) == ["Muhammad Usama", "Alice Smith"])
    }

    // MARK: Active speaker

    @Test("no active speaker in the solo muted dump (the honest current state)")
    func activeSolo() {
        let tree = soloTree()
        #expect(ZoomAX.activeSpeaker(in: tree, roster: ZoomAX.roster(in: tree)) == nil)
    }

    @Test("an active-speaker marker resolves to the roster name")
    func activeMarker() {
        let tree = twoPersonTalking()
        let who = ZoomAX.activeSpeaker(in: tree, roster: ZoomAX.roster(in: tree))
        #expect(who?.name == "Alice Smith")
        #expect(who?.strategy == "marker")
    }

    @Test("a soft speaking marker still resolves when it carries a roster name")
    func activeSoftMarker() {
        let tree = AXNode(role: "AXApplication", children: [
            AXNode(role: "AXOutline", desc: "Participants list", children: [
                AXNode(role: "AXRow", children: [AXNode(role: "AXCell", children: [
                    AXNode(role: "AXStaticText", value: "Bob Lee (me)"),
                    AXNode(role: "AXButton", desc: "Mute"),
                ])]),
            ]),
            AXNode(role: "AXStaticText", value: "Bob Lee speaking"),
        ])
        let who = ZoomAX.activeSpeaker(in: tree, roster: ZoomAX.roster(in: tree))
        #expect(who?.name == "Bob Lee")
        #expect(who?.strategy == "marker-soft")
    }

    @Test("hard marker resolves with no roster (participants panel closed)")
    func activeNoRoster() {
        let tree = AXNode(role: "AXApplication", children: [
            AXNode(role: "AXImage", desc: "Carol Diaz, active speaker"),
        ])
        let who = ZoomAX.activeSpeaker(in: tree, roster: [])
        #expect(who?.name == "Carol Diaz")
        #expect(who?.strategy == "marker-noroster")
    }

    // MARK: Mute state + count

    @Test("mute state reads the muted solo participant")
    func muteSolo() {
        let states = ZoomAX.muteStates(in: soloTree())
        #expect(states == [ZoomAX.MuteState(name: "Muhammad Usama", muted: true, videoOff: true)])
    }

    @Test("participant count parses 'Participants (N)'")
    func count() {
        #expect(ZoomAX.participantCount(in: soloTree()) == 1)
        #expect(ZoomAX.participantCount(in: twoPersonTalking()) == 2)
    }

    // MARK: Diagnostics / change detection (the auto-capture payload)

    @Test("diagnostics surface the marker node that appears when someone starts talking")
    func changeDetection() {
        let before = soloTree()
        // Same call, now Alice starts talking: an active-speaker marker node appears.
        var after = soloTree()
        after.children[0].children.append(AXNode(role: "AXImage", desc: "Alice Smith, active speaker"))
        let roster = ZoomAX.roster(in: after)
        let diag = ZoomAX.diagnostics(in: after, previous: before, roster: roster)
        #expect(diag.contains("Alice Smith, active speaker"))
        #expect(diag.contains("changed +:"))
    }
}
