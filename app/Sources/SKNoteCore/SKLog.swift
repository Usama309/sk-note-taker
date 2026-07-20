import Foundation

/// Severity. `error` entries are additionally written to the errors-only file.
public enum LogLevel: String, Sendable, Comparable {
    case debug = "DEBUG"
    case info  = "INFO "
    case warn  = "WARN "
    case error = "ERROR"

    var rank: Int {
        switch self {
        case .debug: 0
        case .info:  1
        case .warn:  2
        case .error: 3
        }
    }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// Subsystem an entry came from — the first thing you want when scanning a log.
public enum LogCategory: String, Sendable {
    case app
    case session
    case capture        // system audio (ScreenCaptureKit / process tap)
    case mic
    case transcription
    case diarization
    case recording
    case ai
    case sync
    case store
    case permissions
}

/// Stable, greppable error codes. Never renumber one that has shipped — an old log should
/// always be readable against a newer build.
public enum SKErrorCode: String, Sendable {
    // Capture — system audio
    case captureScreenPermissionDenied = "CAP-001"
    case captureNoDisplay              = "CAP-002"
    case captureStartFailed            = "CAP-003"
    case captureStalled                = "CAP-004"
    case captureRestartFailed          = "CAP-005"
    case captureStreamError            = "CAP-006"
    case captureFellBackToTap          = "CAP-007"
    // Capture — Core Audio process tap (fallback path)
    case tapCreateFailed               = "TAP-001"
    case tapAggregateFailed            = "TAP-002"
    case tapFormatUnreadable           = "TAP-003"
    case tapIOProcFailed               = "TAP-004"
    case tapStartFailed                = "TAP-005"
    case tapRebuildFailed              = "TAP-006"
    // Microphone
    case micPermissionDenied           = "MIC-001"
    case micDeviceUnavailable          = "MIC-002"
    case micStartFailed                = "MIC-003"
    case micSilent                     = "MIC-004"
    // Pipeline
    case transcriptionStreamEnded      = "ASR-001"
    case transcriptionModelFailed      = "ASR-002"
    case diarizationPassFailed         = "DIA-001"
    case diarizationPrepareFailed      = "DIA-002"
    case recordingWriteFailed          = "REC-001"
    case recordingStartFailed          = "REC-002"
    // Higher level
    case sessionStartFailed            = "SES-001"
    case sessionSaveFailed             = "SES-002"
    case aiRequestFailed               = "AI-001"
    case aiUnavailable                 = "AI-002"
    case syncFailed                    = "SYN-001"
    case storeReadFailed               = "STO-001"
    case storeWriteFailed              = "STO-002"
    case loginItemFailed               = "APP-001"
}

/// Central logging for SK Note Taker.
///
/// WHY THIS EXISTS: the app writes its diagnostics to stderr, which is discarded when it is
/// launched from Finder — so a capture failure mid-meeting left no trace at all and had to be
/// reverse-engineered from the recorded audio. Everything now lands in two files on the
/// Desktop, where they can be checked after a meeting without any tooling:
///
///   ~/Desktop/SK Note Taker Logs/sknotetaker.log   every entry, chronological
///   ~/Desktop/SK Note Taker Logs/errors.log        errors only, one detailed block each
///
/// Errors carry a stable code (see `SKErrorCode`), the underlying error's domain/code where
/// available, and the meeting they happened in.
public enum SKLog {

    // MARK: - Configuration

    /// Minimum level written to the full log. Errors always go to the errors file.
    public nonisolated(unsafe) static var minimumLevel: LogLevel = .info
    /// Rotate once a file passes this size, keeping one previous generation.
    private static let maxBytes = 10 * 1024 * 1024

    /// Overrides the log location (tests only — production always writes to the Desktop).
    public nonisolated(unsafe) static var directoryOverride: URL?

    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("SK Note Taker Logs", isDirectory: true)
    }

    /// Test seam: point the log at a temp directory and start from a clean slate.
    public static func resetForTesting(directory: URL) {
        lock.lock()
        directoryOverride = directory
        didBootstrap = false
        meetingContext = nil
        errorCount = 0
        warnCount = 0
        lock.unlock()
    }
    public static var fullLogURL: URL { directory.appendingPathComponent("sknotetaker.log") }
    public static var errorLogURL: URL { directory.appendingPathComponent("errors.log") }

    // MARK: - State

    private static let lock = NSLock()
    /// Meeting the entries belong to, so an error can be traced to a specific call.
    private nonisolated(unsafe) static var meetingContext: String?
    private nonisolated(unsafe) static var errorCount = 0
    private nonisolated(unsafe) static var warnCount = 0
    private nonisolated(unsafe) static var didBootstrap = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Public API

    public static func debug(_ category: LogCategory, _ message: String) {
        write(.debug, category, message)
    }
    public static func info(_ category: LogCategory, _ message: String) {
        write(.info, category, message)
    }
    public static func warn(_ category: LogCategory, _ message: String) {
        write(.warn, category, message)
    }

    /// Logs an error to BOTH files: a one-line entry in the full log, and a detailed block in
    /// the errors file with the code, underlying domain/code and meeting context.
    public static func error(_ code: SKErrorCode, _ category: LogCategory,
                             _ message: String, error: Error? = nil) {
        var line = "[\(code.rawValue)] \(message)"
        if let error { line += " — \(error.localizedDescription)" }
        write(.error, category, line)
        writeErrorBlock(code: code, category: category, message: message, error: error)
    }

    /// Marks the start of a meeting in both files, so entries are attributable to a call.
    public static func beginMeeting(title: String, id: UUID) {
        lock.lock(); meetingContext = "\(title) [\(id.uuidString.prefix(8))]"
        errorCount = 0; warnCount = 0; lock.unlock()
        banner("MEETING STARTED: \(title) [\(id.uuidString.prefix(8))]")
    }

    /// Closes out the meeting with a summary line — the first thing to look at afterwards.
    public static func endMeeting(title: String, durationSec: Double) {
        let (e, w) = lock.withLock { (errorCount, warnCount) }
        banner(String(format: "MEETING ENDED: %@ — %.0fs, %d error(s), %d warning(s)",
                      title, durationSec, e, w))
        if e > 0 {
            info(.session, "⚠️ \(e) error(s) this meeting — see \(errorLogURL.path)")
        }
        lock.lock(); meetingContext = nil; lock.unlock()
    }

    /// Errors recorded during the current meeting (for surfacing in the UI).
    public static var currentMeetingErrorCount: Int { lock.withLock { errorCount } }

    // MARK: - Writing

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        if level == .warn { lock.lock(); warnCount += 1; lock.unlock() }
        guard level >= minimumLevel || level == .error else { return }
        let context = lock.withLock { meetingContext }
        var line = "\(stamp.string(from: Date()))  \(level.rawValue)  [\(category.rawValue)] \(message)"
        if let context, level >= .warn { line += "  {\(context)}" }
        append(line + "\n", to: fullLogURL)
        // Mirror to stderr so CLI/diagnostic runs still show output.
        FileHandle.standardError.write(Data("SKNote \(level.rawValue) [\(category.rawValue)] \(message)\n".utf8))
    }

    private static func writeErrorBlock(code: SKErrorCode, category: LogCategory,
                                        message: String, error: Error?) {
        lock.lock(); errorCount += 1; let context = meetingContext; lock.unlock()
        var block = String(repeating: "─", count: 72) + "\n"
        block += "[\(code.rawValue)]  \(stamp.string(from: Date()))\n"
        block += "Category : \(category.rawValue)\n"
        if let context { block += "Meeting  : \(context)\n" }
        block += "Message  : \(message)\n"
        if let error {
            block += "Error    : \(error.localizedDescription)\n"
            let ns = error as NSError
            block += "Domain   : \(ns.domain)   Code: \(ns.code)\n"
            if let reason = ns.localizedFailureReason { block += "Reason   : \(reason)\n" }
            if let suggestion = ns.localizedRecoverySuggestion {
                block += "Recovery : \(suggestion)\n"
            }
            for (key, value) in ns.userInfo where key != NSLocalizedDescriptionKey {
                block += "  \(key): \(value)\n"
            }
        }
        append(block, to: errorLogURL)
    }

    private static func append(_ text: String, to url: URL) {
        lock.lock(); defer { lock.unlock() }
        bootstrapIfNeeded()
        rotateIfNeeded(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Creates the folder and both files on first use, so they always exist to be checked —
    /// an empty errors.log is a meaningful result ("no errors this meeting").
    private static func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in [fullLogURL, errorLogURL] where !fm.fileExists(atPath: url.path) {
            let header = url == errorLogURL
                ? "SK Note Taker — ERRORS ONLY\nEach block: [CODE] timestamp, category, meeting, message, underlying error.\nAn empty file below this header means no errors have been recorded.\n\n"
                : "SK Note Taker — full log\n\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        didBootstrap = false
        bootstrapIfNeeded()
    }

    private static func banner(_ text: String) {
        let bar = String(repeating: "═", count: 72)
        append("\n\(bar)\n\(stamp.string(from: Date()))  \(text)\n\(bar)\n", to: fullLogURL)
        append("\n\(bar)\n\(stamp.string(from: Date()))  \(text)\n\(bar)\n", to: errorLogURL)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
