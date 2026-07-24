import Foundation
import Network

/// A tiny loopback HTTP server that the Google Meet browser extension posts active-speaker names
/// to. The extension reads Meet's page for who is currently speaking and POSTs {"name": "..."}
/// here; the app forwards each name into the transcript via the same path as the Zoom
/// Accessibility reader (MeetingSession.noteActiveSpeaker). Bound to 127.0.0.1 so only local
/// processes can reach it.
public final class MeetSpeakerBridge: @unchecked Sendable {
    public static let defaultPort: UInt16 = 8788

    private let port: UInt16
    private let queue = DispatchQueue(label: "sk.notetaker.meetbridge")
    private let onName: @Sendable (String) -> Void
    private var listener: NWListener?
    private var startCont: CheckedContinuation<Void, Error>?

    public init(port: UInt16 = MeetSpeakerBridge.defaultPort,
                onActiveSpeaker: @escaping @Sendable (String) -> Void) {
        self.port = port
        self.onName = onActiveSpeaker
    }

    public var isRunning: Bool { listener != nil }

    /// Start the loopback server and resolve once it's actually bound (or throw the bind error).
    public func start() async throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.startCont = cont
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let c = self.startCont { self.startCont = nil; c.resume() }
                case .failed(let error):
                    if let c = self.startCont { self.startCont = nil; c.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Per-connection receive buffer (the POST body can arrive in a later TCP segment than the
    /// headers, so we accumulate until the request parses or the connection completes).
    private final class ConnState: @unchecked Sendable { var buffer = Data() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, ConnState())
    }

    private func receive(_ conn: NWConnection, _ st: ConnState) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let data { st.buffer.append(data) }
            let request = String(data: st.buffer, encoding: .utf8) ?? ""
            if let name = Self.parseName(request) {
                self.onName(name); self.respond(conn); return
            }
            if isComplete || error != nil { self.respond(conn); return }
            self.receive(conn, st)   // body not here yet — keep reading
        }
    }

    private func respond(_ conn: NWConnection) {
        // Permissive CORS so the extension's fetch always succeeds; the body is trivial.
        let body = "ok"
        let response = """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: *\r
        Access-Control-Allow-Methods: POST, OPTIONS\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: response.data(using: .utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Extract the active speaker's name from the request: a JSON body {"name":"Alice"} (how the
    /// extension posts) or, as a fallback, a query string ?name=Alice.
    static func parseName(_ request: String) -> String? {
        if let range = request.range(of: "\r\n\r\n") {
            let body = String(request[range.upperBound...])
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        if let line = request.split(separator: "\r\n").first,
           let comps = URLComponents(string: "http://x" + Self.path(of: String(line))),
           let name = comps.queryItems?.first(where: { $0.name == "name" })?.value,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func path(of requestLine: String) -> String {
        guard let start = requestLine.range(of: " "),
              let end = requestLine.range(of: " HTTP") else { return "/" }
        return String(requestLine[start.upperBound..<end.lowerBound])
    }
}
