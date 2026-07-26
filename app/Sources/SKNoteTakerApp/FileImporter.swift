import Foundation
import PDFKit
import SKNoteCore

/// Converts an imported file of almost any kind into plain text for a project's memory: audio and
/// video are transcribed, PDFs and Word/RTF/HTML are extracted, and text/CSV files are read
/// directly.
enum FileImporter {
    static let audioVideoExts: Set<String> = [
        "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "mov", "mp4", "m4v", "mpg", "mpeg",
    ]
    static let docExts: Set<String> = ["doc", "docx", "rtf", "rtfd", "html", "htm", "odt", "webarchive"]
    static let textExts: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml", "text", "",
    ]

    /// True if importing this file will take a while (audio/video is transcribed on device).
    static func isSlow(_ url: URL) -> Bool { audioVideoExts.contains(url.pathExtension.lowercased()) }

    /// Extract the file's content as text, or nil if it can't be read as text.
    static func extractText(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if audioVideoExts.contains(ext) {
            return try? await MeetingReprocessor.transcribeText(fileURL: url)
        }
        if ext == "pdf" {
            return PDFDocument(url: url)?.string
        }
        if docExts.contains(ext) {
            return textutil(url)
        }
        if textExts.contains(ext) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // Unknown: try plain text, then textutil (handles many rich formats).
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        return textutil(url)
    }

    /// Convert a rich document to text using macOS's built-in `textutil`.
    private static func textutil(_ url: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", url.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}
