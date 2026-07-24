import Foundation
import Network
import CryptoKit
import Security

// MARK: - Public model

/// One upcoming event pulled from the user's primary Google calendar.
public struct GoogleCalendarEvent: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    public let meetingURL: URL?

    public init(id: String, title: String, start: Date, end: Date,
                isAllDay: Bool, location: String?, meetingURL: URL?) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.meetingURL = meetingURL
    }
}

public struct GoogleCalendarError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

// MARK: - Service

/// Self-contained Google Calendar sign-in for a desktop app: OAuth 2.0 with a loopback redirect
/// and PKCE (no client secret ever leaves this machine, and none is required to be kept secret).
/// The user clicks "Connect", the system browser opens Google's login, and the loopback server
/// below catches the redirect. Tokens live in the Keychain; the client id/secret the user pasted
/// live there too, so nothing sensitive is written into the repo.
@MainActor
public final class GoogleCalendarService {
    private let scope = "https://www.googleapis.com/auth/calendar.readonly openid email"
    private var state = KeychainStore.load()

    public init() {}

    public var hasCredentials: Bool {
        !(state.clientID ?? "").isEmpty && !(state.clientSecret ?? "").isEmpty
    }
    public var isConnected: Bool { !(state.refreshToken ?? "").isEmpty }
    public var connectedEmail: String? { state.email }
    /// The client ID is not a secret; expose it so Settings can show what's saved (the secret is never surfaced).
    public var savedClientID: String? { state.clientID }

    /// Store the OAuth client the user created in Google Cloud (id + secret).
    public func setCredentials(clientID: String, clientSecret: String) {
        state.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        state.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(state)
    }

    public func disconnect() {
        state.accessToken = nil; state.refreshToken = nil; state.expiry = nil; state.email = nil
        KeychainStore.save(state)
    }

    /// Full browser sign-in. `openURL` is passed in so this stays free of AppKit.
    public func connect(openURL: @escaping (URL) -> Void) async throws {
        guard hasCredentials else {
            throw GoogleCalendarError("Add your Google OAuth client ID and secret first.")
        }
        let verifier = Self.pkceVerifier()
        let challenge = Self.pkceChallenge(verifier)

        let server = try LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: state.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        let code = try await server.waitForCode()
        try await exchange(code: code, verifier: verifier, redirect: redirect)
    }

    /// Upcoming events on the primary calendar, from now forward.
    public func upcomingEvents(days: Int = 14, max: Int = 12) async throws -> [GoogleCalendarEvent] {
        let token = try await validAccessToken()
        let now = Date()
        let until = now.addingTimeInterval(Double(days) * 86_400)
        let iso = ISO8601DateFormatter()

        var comps = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: now)),
            .init(name: "timeMax", value: iso.string(from: until)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: String(max)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleCalendarError("Calendar request failed: \(Self.body(data))")
        }
        let decoded = try JSONDecoder().decode(EventsResponse.self, from: data)
        return decoded.items.compactMap { $0.toEvent() }
    }

    // MARK: Token handling

    private func exchange(code: String, verifier: String, redirect: String) async throws {
        let form = [
            "code": code,
            "client_id": state.clientID ?? "",
            "client_secret": state.clientSecret ?? "",
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let token = try await postToken(form)
        state.accessToken = token.access_token
        if let r = token.refresh_token { state.refreshToken = r }
        state.expiry = Date().addingTimeInterval(Double(token.expires_in ?? 3300))
        if let idt = token.id_token { state.email = Self.email(fromIDToken: idt) }
        KeychainStore.save(state)
    }

    private func validAccessToken() async throws -> String {
        guard isConnected else { throw GoogleCalendarError("Not connected to Google Calendar.") }
        if let tok = state.accessToken, let exp = state.expiry, exp > Date().addingTimeInterval(60) {
            return tok
        }
        let form = [
            "client_id": state.clientID ?? "",
            "client_secret": state.clientSecret ?? "",
            "refresh_token": state.refreshToken ?? "",
            "grant_type": "refresh_token",
        ]
        let token = try await postToken(form)
        state.accessToken = token.access_token
        state.expiry = Date().addingTimeInterval(Double(token.expires_in ?? 3300))
        KeychainStore.save(state)
        return token.access_token
    }

    private func postToken(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleCalendarError("Google sign-in failed: \(Self.body(data))")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Helpers

    private static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    nonisolated static func pkceChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    private static func body(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown error"
    }
    /// Pull the "email" claim out of the id_token JWT (no verification needed — it came straight
    /// from Google's token endpoint over TLS).
    nonisolated static func email(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["email"] as? String
    }
}

// MARK: - Loopback redirect server

/// A one-shot HTTP server on 127.0.0.1 that catches Google's OAuth redirect and hands back the
/// authorization `code`. It listens on an ephemeral port so nothing needs to be pre-registered.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sknote.oauth.loopback")
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var connection: NWConnection?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Start listening and resolve once the OS has assigned a port. `startContinuation` is only
    /// ever touched from the listener queue's state handler, so the one-shot resume is race-free.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            self.startContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue, let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume(returning: port)
                    }
                case .failed(let error):
                    if let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Await the authorization code delivered to the redirect URI.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in self.codeContinuation = cont }
    }

    func stop() {
        connection?.cancel(); connection = nil
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        connection = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = Self.parse(request)
            let ok = (result.error == nil && result.code != nil)
            let html = ok
                ? "<h2>SK Note Taker is connected.</h2><p>You can close this tab and return to the app.</p>"
                : "<h2>Sign-in was cancelled.</h2><p>You can close this tab.</p>"
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            if let cont = self.codeContinuation {
                self.codeContinuation = nil
                if let code = result.code { cont.resume(returning: code) }
                else { cont.resume(throwing: GoogleCalendarError(result.error ?? "No authorization code returned.")) }
            }
        }
    }

    /// Pull `code` / `error` out of the first request line: "GET /?code=... HTTP/1.1".
    private static func parse(_ request: String) -> (code: String?, error: String?) {
        guard let line = request.split(separator: "\r\n").first,
              let pathStart = line.range(of: "GET "),
              let pathEnd = line.range(of: " HTTP") else { return (nil, nil) }
        let path = String(line[pathStart.upperBound..<pathEnd.lowerBound])
        guard let comps = URLComponents(string: "http://127.0.0.1\(path)") else { return (nil, nil) }
        let items = comps.queryItems ?? []
        return (items.first { $0.name == "code" }?.value,
                items.first { $0.name == "error" }?.value)
    }
}

// MARK: - Keychain-backed state

private struct GoogleState: Codable {
    var clientID: String?
    var clientSecret: String?
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
    var email: String?
}

private enum KeychainStore {
    private static let service = "com.saqibkamran.sknotetaker"
    private static let account = "google-calendar"

    static func load() -> GoogleState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let state = try? JSONDecoder().decode(GoogleState.self, from: data)
        else { return GoogleState() }
        return state
    }

    static func save(_ state: GoogleState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Google JSON

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let id_token: String?
}

private struct EventsResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String?
        let summary: String?
        let location: String?
        let hangoutLink: String?
        let status: String?
        let start: When?
        let end: When?

        struct When: Decodable { let dateTime: String?; let date: String? }

        func toEvent() -> GoogleCalendarEvent? {
            guard status != "cancelled", let id, let start, let end else { return nil }
            let iso = ISO8601DateFormatter()
            let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current

            func parse(_ w: When) -> (Date, Bool)? {
                if let dt = w.dateTime, let d = iso.date(from: dt) { return (d, false) }
                if let d = w.date, let parsed = day.date(from: d) { return (parsed, true) }
                return nil
            }
            guard let (s, allDay) = parse(start), let (e, _) = parse(end) else { return nil }
            return GoogleCalendarEvent(
                id: id, title: summary ?? "(no title)", start: s, end: e,
                isAllDay: allDay, location: location,
                meetingURL: hangoutLink.flatMap(URL.init(string:)))
        }
    }
}
