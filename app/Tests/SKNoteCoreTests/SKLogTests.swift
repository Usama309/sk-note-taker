import Foundation
import Testing
@testable import SKNoteCore

/// The previous capture failure was invisible because diagnostics went to stderr, which is
/// discarded for a Finder-launched app. These pin the behaviour that replaced it.
@Suite("SKLog", .serialized)
struct SKLogTests {

    /// Fresh temp directory per test — never touches the real Desktop.
    private func withTempLog(_ body: (URL) throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sklog-\(UUID().uuidString)", isDirectory: true)
        SKLog.resetForTesting(directory: dir)
        defer {
            try? FileManager.default.removeItem(at: dir)
            SKLog.directoryOverride = nil
        }
        try body(dir)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func bothFilesAreCreatedOnFirstUse() throws {
        try withTempLog { _ in
            SKLog.info(.app, "hello")
            #expect(FileManager.default.fileExists(atPath: SKLog.fullLogURL.path),
                    "the full log must exist so it can be checked after a meeting")
            #expect(FileManager.default.fileExists(atPath: SKLog.errorLogURL.path),
                    "the errors file must exist even with no errors — empty is a real answer")
        }
    }

    @Test func errorGoesToBothFilesWithItsCode() throws {
        try withTempLog { _ in
            struct Boom: Error {}
            SKLog.error(.captureStalled, .capture, "capture went deaf", error: Boom())
            let full = read(SKLog.fullLogURL), errors = read(SKLog.errorLogURL)
            #expect(full.contains("CAP-004"), "full log should carry the code")
            #expect(full.contains("capture went deaf"))
            #expect(errors.contains("CAP-004"), "errors file should carry the code")
            #expect(errors.contains("Category : capture"))
            #expect(errors.contains("capture went deaf"))
        }
    }

    @Test func informationalEntriesStayOutOfTheErrorsFile() throws {
        try withTempLog { _ in
            SKLog.info(.capture, "stream started")
            SKLog.warn(.mic, "mic quiet")
            let errors = read(SKLog.errorLogURL)
            #expect(!errors.contains("stream started"),
                    "errors.log must stay signal-only, or it stops being useful")
            #expect(!errors.contains("mic quiet"))
            #expect(read(SKLog.fullLogURL).contains("stream started"))
        }
    }

    @Test func underlyingNSErrorDetailIsRecorded() throws {
        try withTempLog { _ in
            let underlying = NSError(domain: "com.apple.coreaudio", code: -10877,
                                     userInfo: [NSLocalizedDescriptionKey: "no such device"])
            SKLog.error(.tapStartFailed, .capture, "tap failed to start", error: underlying)
            let errors = read(SKLog.errorLogURL)
            #expect(errors.contains("com.apple.coreaudio"), "domain is needed to diagnose")
            #expect(errors.contains("-10877"), "the OS status code is the actionable part")
            #expect(errors.contains("no such device"))
        }
    }

    @Test func meetingContextIsAttachedToErrors() throws {
        try withTempLog { _ in
            let id = UUID()
            SKLog.beginMeeting(title: "Quarterly Review", id: id)
            SKLog.error(.captureStalled, .capture, "went deaf mid-call")
            let errors = read(SKLog.errorLogURL)
            #expect(errors.contains("Quarterly Review"),
                    "an error must be traceable to the meeting it happened in")
            #expect(errors.contains(String(id.uuidString.prefix(8))))
        }
    }

    @Test func meetingSummaryReportsTheErrorCount() throws {
        try withTempLog { _ in
            SKLog.beginMeeting(title: "Standup", id: UUID())
            SKLog.error(.diarizationPassFailed, .diarization, "one")
            SKLog.error(.recordingWriteFailed, .recording, "two")
            #expect(SKLog.currentMeetingErrorCount == 2)
            SKLog.endMeeting(title: "Standup", durationSec: 120)
            #expect(read(SKLog.fullLogURL).contains("2 error(s)"),
                    "the end-of-meeting line is the first thing you read")
        }
    }

    @Test func errorCountResetsBetweenMeetings() throws {
        try withTempLog { _ in
            SKLog.beginMeeting(title: "First", id: UUID())
            SKLog.error(.syncFailed, .sync, "boom")
            SKLog.endMeeting(title: "First", durationSec: 10)
            SKLog.beginMeeting(title: "Second", id: UUID())
            #expect(SKLog.currentMeetingErrorCount == 0,
                    "a clean meeting must not inherit the previous meeting's errors")
        }
    }

    @Test func errorCodesAreUnique() {
        // A duplicated raw value would make logs ambiguous to grep.
        let codes: [SKErrorCode] = [
            .captureScreenPermissionDenied, .captureNoDisplay, .captureStartFailed,
            .captureStalled, .captureRestartFailed, .captureStreamError, .captureFellBackToTap,
            .tapCreateFailed, .tapAggregateFailed, .tapFormatUnreadable, .tapIOProcFailed,
            .tapStartFailed, .tapRebuildFailed,
            .micPermissionDenied, .micDeviceUnavailable, .micStartFailed, .micSilent,
            .transcriptionStreamEnded, .transcriptionModelFailed,
            .diarizationPassFailed, .diarizationPrepareFailed,
            .recordingWriteFailed, .recordingStartFailed,
            .sessionStartFailed, .sessionSaveFailed,
            .aiRequestFailed, .aiUnavailable, .syncFailed,
            .storeReadFailed, .storeWriteFailed, .loginItemFailed,
        ]
        #expect(Set(codes.map(\.rawValue)).count == codes.count)
    }
}
