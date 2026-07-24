import Foundation
import Testing
@testable import SKNoteCore

@Suite("Meet speaker bridge")
struct MeetSpeakerBridgeTests {
    final class NameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String) { lock.withLock { value = v } }
        func get() -> String? { lock.withLock { value } }
    }

    @Test("parses the name from a JSON POST body")
    func parsesJSON() {
        let req = "POST /speaker HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"name\":\"Alice Smith\"}"
        #expect(MeetSpeakerBridge.parseName(req) == "Alice Smith")
    }

    @Test("parses the name from a query fallback")
    func parsesQuery() {
        let req = "GET /?name=Bob%20Jones HTTP/1.1\r\nHost: x\r\n\r\n"
        #expect(MeetSpeakerBridge.parseName(req) == "Bob Jones")
    }

    @Test("ignores a blank or missing name")
    func ignoresBlank() {
        #expect(MeetSpeakerBridge.parseName("POST / HTTP/1.1\r\n\r\n{\"name\":\"  \"}") == nil)
        #expect(MeetSpeakerBridge.parseName("POST / HTTP/1.1\r\n\r\n{}") == nil)
    }

    @Test("delivers a posted name end to end over the loopback socket")
    func endToEnd() async throws {
        let box = NameBox()
        let bridge = MeetSpeakerBridge(port: 8791) { box.set($0) }
        try await bridge.start()
        defer { bridge.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:8791/speaker")!)
        req.httpMethod = "POST"
        req.httpBody = "{\"name\":\"Charlie\"}".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)

        try await Task.sleep(for: .milliseconds(200))
        #expect(box.get() == "Charlie")
    }
}
