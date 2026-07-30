import SwiftUI
import AppKit

/// Detects whether macOS Mission Control (or Exposé / the Spaces overview) is currently on screen,
/// using ONLY the public CGWindowList API — no private symbols, so nothing to break on OS updates.
///
/// Empirically (see `--selftest-mcdetect`), when Mission Control opens the Dock draws windows at a
/// high layer (18/20) sized to the whole display, and they vanish the instant it closes. The normal
/// Dock is a thin strip, so "a Dock-owned window that covers a full screen" is a clean signal.
///
/// Mission Control renders live window contents, so flipping the app to a branded overlay while it
/// is active makes the app's Mission Control thumbnail show the logo + "SK Note Taker is here",
/// then revert the moment it closes.
@MainActor
final class MissionControlMonitor {
    private var timer: Timer?
    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?

    func start() {
        guard timer == nil else { return }
        // 0.18s is fast enough that the overlay is in place before the user's eye settles on the
        // thumbnail, and cheap (one CGWindowList snapshot per tick).
        let t = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let active = Self.missionControlOnScreen()
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }

    /// True when Mission Control / Exposé / the Spaces overview is on screen.
    ///
    /// Signature confirmed empirically (`--selftest-mcwindows` across toggles): Mission Control's
    /// dimming backdrop is a Dock-owned, full-screen window at layer ~18. A *different* Dock-owned
    /// full-screen window sits at layer 20 permanently (even when MC is closed), so matching "layer
    /// >= 18" false-positived and pinned the overlay on. We match only the ~18 backdrop and exclude
    /// 20. This fails safe: if the layer ever shifts, the overlay simply stops appearing rather than
    /// covering the app during normal use.
    static func missionControlOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        guard !screens.isEmpty else { return false }
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "Dock",
                  (16...19).contains((w[kCGWindowLayer as String] as? Int) ?? 0),
                  let bd = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: bd as! CFDictionary) else { continue }
            for s in screens where r.width >= s.width * 0.9 && r.height >= s.height * 0.9 {
                return true
            }
        }
        return false
    }
}

/// The Mission-Control-only brand card: the app dims + blurs behind a centered logo and wordmark.
/// Shown only while `MissionControlMonitor` reports active, so it never appears in normal use.
struct MissionControlBrandOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.34)
            VStack(spacing: 20) {
                LogoMark(size: 104)
                    .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
                Text("SK Note Taker is here")
                    .font(.skDisplay)
                    .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // never intercept clicks, even for the frame it lingers
    }
}
