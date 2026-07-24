import Foundation
import Testing
@testable import SKNoteCore

/// Tests for the parts of the Google Calendar sign-in that don't need a live Google account:
/// PKCE (against the RFC 7636 vector), the id_token email parse, and the loopback redirect capture
/// (the custom, riskiest bit of the OAuth flow).
@Suite("Google Calendar OAuth")
struct GoogleCalendarTests {

    @Test("PKCE S256 challenge matches the RFC 7636 reference vector")
    func pkceMatchesRFC() {
        // From RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = GoogleCalendarService.pkceChallenge(verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("email claim is extracted from an id_token JWT")
    func emailFromJWT() {
        let header = GoogleCalendarService.base64URL(Data(#"{"alg":"RS256"}"#.utf8))
        let payload = GoogleCalendarService.base64URL(Data(#"{"email":"me@example.com","email_verified":true}"#.utf8))
        let jwt = "\(header).\(payload).signature-not-checked"
        #expect(GoogleCalendarService.email(fromIDToken: jwt) == "me@example.com")
    }

    @Test("a malformed id_token yields nil rather than crashing")
    func emailFromGarbage() {
        #expect(GoogleCalendarService.email(fromIDToken: "not-a-jwt") == nil)
        #expect(GoogleCalendarService.email(fromIDToken: "a.b") == nil)
    }

    @Test("loopback server returns the authorization code delivered to the redirect URI")
    func loopbackCapturesCode() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        #expect(port > 0)

        async let captured = server.waitForCode()
        let url = URL(string: "http://127.0.0.1:\(port)/?code=ABC123&scope=calendar")!
        _ = try? await URLSession.shared.data(from: url)

        let code = try await captured
        #expect(code == "ABC123")
        server.stop()
    }

    @Test("loopback server surfaces an error redirect (user declined) as a thrown error")
    func loopbackHandlesError() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()

        async let captured = server.waitForCode()
        let url = URL(string: "http://127.0.0.1:\(port)/?error=access_denied")!
        _ = try? await URLSession.shared.data(from: url)

        var threw = false
        do { _ = try await captured } catch { threw = true }
        #expect(threw)
        server.stop()
    }
}
