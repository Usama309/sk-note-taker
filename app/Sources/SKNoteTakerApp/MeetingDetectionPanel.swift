import SwiftUI
import AppKit
import SKNoteCore

@Observable @MainActor
final class DetectionPanelModel {
    var appName = ""
    var progress: Double = 1      // 1 → 0 as the bar drains
    var paused = false
}

/// Custom floating "you're in a meeting" popup: top-right of the screen, above all apps (even a
/// fullscreen call), stays ~40s with a draining bar, and a Start Notes CTA that launches straight
/// into compact mode. A system notification can't control its lifetime, draw a bar, or choose the
/// launch target — this can.
@MainActor
final class MeetingDetectionPanel {
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private let model = DetectionPanelModel()
    private var onStart: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private let duration: Double = 40

    func show(appName: String,
              onStartNotes: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        close()
        self.onStart = onStartNotes
        self.onDismiss = onDismiss
        model.appName = appName
        model.progress = 1
        model.paused = false

        let width: CGFloat = 384, height: CGFloat = 132
        let hosting = NSHostingView(rootView: DetectionPanelView(
            model: model,
            onStart: { [weak self] in self?.fire(start: true) },
            onDismiss: { [weak self] in self?.fire(start: false) }))
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
                if self.model.paused { continue }        // hover freezes the countdown
                elapsed += 0.05
                self.model.progress = max(0, 1 - elapsed / self.duration)
                if elapsed >= self.duration { self.fire(start: false); return }
            }
        }
    }

    private func fire(start: Bool) {
        let s = onStart, d = onDismiss
        close()
        if start { s?() } else { d?() }
    }

    func close() {
        ticker?.cancel(); ticker = nil
        panel?.orderOut(nil); panel = nil
        onStart = nil; onDismiss = nil
    }
}

struct DetectionPanelView: View {
    @Bindable var model: DetectionPanelModel
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You're in a \(model.appName) meeting")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Take live notes with SK Note Taker?")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(action: onStart) {
                            Text("Start Notes")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Theme.accentGradient, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        Button(action: onDismiss) {
                            Text("Not now")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(0, geo.size.width * model.progress))
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .padding(12)
        .onHover { model.paused = $0 }
    }
}
