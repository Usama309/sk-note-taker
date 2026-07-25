import SwiftUI
import AppKit
import ScreenCaptureKit
import SKNoteCore

/// Carries a non-Sendable `SCContentFilter` across a `Task` boundary. Safe: constructed once from a
/// picked source and consumed once when the recording starts.
struct SendableSCFilter: @unchecked Sendable {
    let value: SCContentFilter
    init(_ value: SCContentFilter) { self.value = value }
}

// MARK: - Top-right "record your screen?" popup (same style as the note-taking popup)

@Observable @MainActor
final class ScreenRecordPromptModel {
    var progress: Double = 0
    var paused = false
}

/// A floating top-right notification asking whether to record the screen. Modeled on
/// `MeetingDetectionPanel`: above all apps, hover pauses, auto-dismisses. Offers a one-click
/// "Whole screen" and a "Choose window" that opens the in-app source picker.
@MainActor
final class ScreenRecordPromptPanel {
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private let model = ScreenRecordPromptModel()
    private let duration: Double = 25

    func show(onWholeScreen: @escaping () -> Void,
              onChoose: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        close()
        model.progress = 0
        model.paused = false

        let width: CGFloat = 384, height: CGFloat = 150
        let hosting = NSHostingView(rootView: ScreenRecordPromptView(
            model: model,
            onWholeScreen: { [weak self] in self?.close(); onWholeScreen() },
            onChoose: { [weak self] in self?.close(); onChoose() },
            onDismiss: { [weak self] in self?.close(); onDismiss() }))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        if let vf = NSScreen.main?.visibleFrame {
            let margin: CGFloat = 12
            panel.setFrameOrigin(NSPoint(x: vf.maxX - width - margin, y: vf.maxY - height - margin))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        ticker = Task { [weak self] in
            var elapsed = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if self.model.paused { continue }
                elapsed += 0.05
                self.model.progress = min(1, elapsed / self.duration)
                if elapsed >= self.duration { self.close(); return }
            }
        }
    }

    func close() {
        ticker?.cancel(); ticker = nil
        panel?.orderOut(nil); panel = nil
    }
}

struct ScreenRecordPromptView: View {
    @Bindable var model: ScreenRecordPromptModel
    let onWholeScreen: () -> Void
    let onChoose: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record your screen?")
                        .font(.skSubtitle).foregroundStyle(.primary)
                    Text("Capture a window or the whole screen with this meeting.")
                        .font(.skCallout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: onChoose) {
                    Text("Choose window")
                        .font(.skSubtitle)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Theme.accentGradient,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button(action: onWholeScreen) {
                    Text("Whole screen")
                        .font(.skSubtitle)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.quaternary,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(0, geo.size.width * model.progress))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment: .topLeading) {
            CloseChip(action: onDismiss)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .offset(x: -7, y: -7)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .padding(12)
        .onHover { h in hovering = h; model.paused = h }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - In-app source picker (reliable, does not fight the meeting's audio capture)

/// A sheet listing the displays and open windows to record. Picking one builds an `SCContentFilter`
/// ourselves and hands it back — avoiding `SCContentSharingPicker`, which collides with the running
/// system-audio stream and shows the "Currently Sharing" control instead of a chooser.
struct ScreenSourceSheet: View {
    let onPick: (SCContentFilter) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose what to record").font(.skTitle)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if let errorText {
                ContentUnavailableView("Can't list your screens", systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Entire screen") {
                        ForEach(displays, id: \.displayID) { d in
                            Button { pick(SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])) } label: {
                                Label("Whole screen  (\(d.width)×\(d.height))", systemImage: "display")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section("A window") {
                        if windows.isEmpty {
                            Text("No shareable windows open").foregroundStyle(.secondary)
                        }
                        ForEach(windows, id: \.windowID) { w in
                            Button { pick(SCContentFilter(desktopIndependentWindow: w)) } label: {
                                HStack(spacing: 10) {
                                    if let icon = appIcon(w) {
                                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                    } else {
                                        Image(systemName: "macwindow").frame(width: 22, height: 22)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(w.owningApplication?.applicationName ?? "Window")
                                            .font(.skSubtitle)
                                        if let t = w.title, !t.isEmpty {
                                            Text(t).font(.skCaption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 520)
        .task { await load() }
    }

    private func pick(_ filter: SCContentFilter) {
        onPick(filter)
        dismiss()
    }

    private func appIcon(_ w: SCWindow) -> NSImage? {
        guard let pid = w.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    private func load() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let mine = Bundle.main.bundleIdentifier
            displays = content.displays
            windows = content.windows
                .filter { w in
                    w.isOnScreen
                        && (w.frame.width * w.frame.height) >= 40_000
                        && (w.title?.isEmpty == false)
                        && w.owningApplication?.bundleIdentifier != mine
                }
                .sorted {
                    ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "")
                }
            loaded = true
        } catch {
            errorText = "Screen Recording permission is required. Turn it on in System Settings › Privacy & Security › Screen Recording, then reopen SK Note Taker."
            loaded = true
        }
    }
}
