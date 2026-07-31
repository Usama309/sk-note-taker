import Foundation

// MARK: - Meeting

public enum MeetingState: String, Codable, Sendable {
    case recording
    case processing
    case complete
}

public enum AudioChannel: String, Codable, Sendable {
    case mic
    case system
}

public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var label: String          // "Speaker 1"
    public var name: String?          // "Kainat" — user-assigned
    public var source: AudioChannel

    public init(label: String, name: String? = nil, source: AudioChannel) {
        self.label = label
        self.name = name
        self.source = source
    }

    /// Display name: user-assigned name if set, otherwise the generic label.
    public var displayName: String { name?.isEmpty == false ? name! : label }
}

public struct AutoCategory: Codable, Sendable, Equatable {
    public var project: String?
    public var client: String?
    public var confidence: Double

    public init(project: String?, client: String?, confidence: Double) {
        self.project = project
        self.client = client
        self.confidence = confidence
    }
}

public struct Meeting: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var folderId: UUID?
    public var state: MeetingState
    /// Stable speaker key ("S1", "S2", …) → info. Renaming only touches this map;
    /// transcript segments always reference the key.
    public var speakers: [String: SpeakerInfo]
    public var hasRecording: Bool
    public var durationSec: Double
    public var autoCategory: AutoCategory?
    /// Optional so old meeting.json files (which lack the key) still decode: absent -> nil.
    public var hasScreenRecording: Bool?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        folderId: UUID? = nil,
        state: MeetingState = .recording,
        speakers: [String: SpeakerInfo] = [:],
        hasRecording: Bool = false,
        durationSec: Double = 0,
        autoCategory: AutoCategory? = nil,
        hasScreenRecording: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.folderId = folderId
        self.state = state
        self.speakers = speakers
        self.hasRecording = hasRecording
        self.durationSec = durationSec
        self.autoCategory = autoCategory
        self.hasScreenRecording = hasScreenRecording
    }

    public func displayName(forSpeakerKey key: String) -> String {
        speakers[key]?.displayName ?? key
    }

    /// Whether a screen recording was saved for this meeting.
    public var recordedScreen: Bool { hasScreenRecording == true }
}

// MARK: - Transcript

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var speaker: String        // speaker key: "S1", "S2", …
    public var source: AudioChannel
    public var start: Double          // seconds from meeting start
    public var end: Double
    public var text: String
    public var final: Bool

    public init(id: Int, speaker: String, source: AudioChannel,
                start: Double, end: Double, text: String, final: Bool = true) {
        self.id = id
        self.speaker = speaker
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.final = final
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var version: Int
    public var segments: [TranscriptSegment]

    public init(version: Int = 1, segments: [TranscriptSegment] = []) {
        self.version = version
        self.segments = segments
    }

    /// Plain-text rendering with resolved speaker names, e.g. "[03:12] Kainat: …".
    public func rendered(with meeting: Meeting) -> String {
        segments.filter(\.final).map { seg in
            let m = Int(seg.start) / 60, s = Int(seg.start) % 60
            let name = meeting.displayName(forSpeakerKey: seg.speaker)
            return String(format: "[%02d:%02d] %@: %@", m, s, name, seg.text)
        }.joined(separator: "\n")
    }
}

// MARK: - Folders

public enum FolderKind: String, Codable, Sendable {
    case client
    case project
    case generic
}

public struct Folder: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: FolderKind
    public var parentId: UUID?

    public init(id: UUID = UUID(), name: String, kind: FolderKind = .generic, parentId: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentId = parentId
    }
}

// MARK: - Chat

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public var role: String   // "user" | "assistant"
    public var text: String
    public var at: Date

    public var id: Date { at }

    public init(role: String, text: String, at: Date = Date()) {
        self.role = role
        self.text = text
        self.at = at
    }
}

public struct ChatLog: Codable, Sendable, Equatable {
    public var messages: [ChatMessage]
    public init(messages: [ChatMessage] = []) { self.messages = messages }
}

// MARK: - Summary

/// Structured fields extracted by the AI summary, stored as YAML front-matter in summary.md.
public struct SummaryData: Codable, Sendable, Equatable {
    public struct ActionItem: Codable, Sendable, Equatable {
        public var owner: String?
        public var text: String
        public init(owner: String? = nil, text: String) {
            self.owner = owner
            self.text = text
        }
    }

    public var generatedAt: Date
    public var actionItems: [ActionItem]
    public var decisions: [String]
    public var remember: [String]
    public var body: String            // markdown prose

    public init(generatedAt: Date = Date(), actionItems: [ActionItem] = [],
                decisions: [String] = [], remember: [String] = [], body: String = "") {
        self.generatedAt = generatedAt
        self.actionItems = actionItems
        self.decisions = decisions
        self.remember = remember
        self.body = body
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable, Equatable {
    public var claudeModel: String
    public var defaultSpeakerName: String?   // name for S1 (the machine owner)
    public var locale: String
    /// Auto-detect Zoom/Teams/WhatsApp/Meet calls and offer to take notes. On by default.
    public var autoDetectMeetings: Bool
    /// Launch SK Note Taker automatically when the Mac starts. On by default.
    public var launchAtLogin: Bool
    /// Notice when the meeting seems over (silence / goodbyes), ask, and auto-end. On by default.
    public var autoEndDetection: Bool
    /// Minutes of continuous audio silence before the end prompt fires.
    public var autoEndSilenceMinutes: Double
    /// Generate the AI summary automatically when a meeting ends. On by default.
    public var autoSummarize: Bool
    /// Show the next calendar meeting + countdown in the macOS menu bar. On by default.
    public var showUpcomingInMenuBar: Bool
    /// Include events with no participants / no video link in the Upcoming list. On by default.
    public var showEventsWithoutParticipants: Bool
    /// Google calendar ids whose events appear in Upcoming. Empty means "not yet chosen" —
    /// seed from each calendar's Google-side `selected` flag on first load.
    public var visibleCalendarIds: [String]
    /// When a meeting starts, ask whether to also record the screen. On by default.
    public var askToRecordScreen: Bool
    /// Let the live copilot search the web when an answer is not in project memory. On by default.
    public var assistantWebSearch: Bool
    /// Proactively suggest an answer when someone asks the user a question mid-meeting. On by default.
    public var assistantAutoSuggest: Bool
    /// Soft cues for recording start/stop and deliberate saves. On by default; never during typing.
    public var uiSounds: Bool

    public init(claudeModel: String = "sonnet", defaultSpeakerName: String? = nil,
                locale: String = "en-US", autoDetectMeetings: Bool = true,
                launchAtLogin: Bool = true, autoEndDetection: Bool = true,
                autoEndSilenceMinutes: Double = 2, autoSummarize: Bool = true,
                showUpcomingInMenuBar: Bool = true, showEventsWithoutParticipants: Bool = true,
                visibleCalendarIds: [String] = [], askToRecordScreen: Bool = true,
                assistantWebSearch: Bool = true, assistantAutoSuggest: Bool = true,
                uiSounds: Bool = true) {
        self.claudeModel = claudeModel
        self.defaultSpeakerName = defaultSpeakerName
        self.locale = locale
        self.autoDetectMeetings = autoDetectMeetings
        self.launchAtLogin = launchAtLogin
        self.autoEndDetection = autoEndDetection
        self.autoEndSilenceMinutes = autoEndSilenceMinutes
        self.autoSummarize = autoSummarize
        self.showUpcomingInMenuBar = showUpcomingInMenuBar
        self.showEventsWithoutParticipants = showEventsWithoutParticipants
        self.visibleCalendarIds = visibleCalendarIds
        self.askToRecordScreen = askToRecordScreen
        self.assistantWebSearch = assistantWebSearch
        self.assistantAutoSuggest = assistantAutoSuggest
        self.uiSounds = uiSounds
    }

    // Tolerant decode: older settings.json without new fields default to on.
    private enum CodingKeys: String, CodingKey {
        case claudeModel, defaultSpeakerName, locale, autoDetectMeetings, launchAtLogin
        case autoEndDetection, autoEndSilenceMinutes, autoSummarize
        case showUpcomingInMenuBar, showEventsWithoutParticipants, visibleCalendarIds
        case askToRecordScreen, assistantWebSearch, assistantAutoSuggest, uiSounds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "sonnet"
        defaultSpeakerName = try c.decodeIfPresent(String.self, forKey: .defaultSpeakerName)
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
        autoDetectMeetings = try c.decodeIfPresent(Bool.self, forKey: .autoDetectMeetings) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        autoEndDetection = try c.decodeIfPresent(Bool.self, forKey: .autoEndDetection) ?? true
        autoEndSilenceMinutes =
            try c.decodeIfPresent(Double.self, forKey: .autoEndSilenceMinutes) ?? 2
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? true
        showUpcomingInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showUpcomingInMenuBar) ?? true
        showEventsWithoutParticipants =
            try c.decodeIfPresent(Bool.self, forKey: .showEventsWithoutParticipants) ?? true
        visibleCalendarIds = try c.decodeIfPresent([String].self, forKey: .visibleCalendarIds) ?? []
        askToRecordScreen = try c.decodeIfPresent(Bool.self, forKey: .askToRecordScreen) ?? true
        assistantWebSearch = try c.decodeIfPresent(Bool.self, forKey: .assistantWebSearch) ?? true
        assistantAutoSuggest = try c.decodeIfPresent(Bool.self, forKey: .assistantAutoSuggest) ?? true
        uiSounds = try c.decodeIfPresent(Bool.self, forKey: .uiSounds) ?? true
    }
}

// MARK: - JSON coding helpers

public enum SKJSON {
    // ISO8601 with fractional seconds so Dates round-trip losslessly (and stay readable
    // to the Node-based MCP/web tooling).
    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter().string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter().date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unparseable date: \(raw)"))
        }
        return d
    }
}
