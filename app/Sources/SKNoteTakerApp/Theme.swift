import SwiftUI
import AppKit

/// SK Note Taker brand system — charcoal + mint, Apple-clean, in light and dark. Colours are the
/// single source of truth; use these tokens (not raw hex) everywhere.
enum Theme {
    // MARK: Brand
    static let mint      = Color(hex: "78C6A3")   // primary mint (accent / hover / fills)
    static let mintLight = Color(hex: "A6DEC6")
    static let mintSoft  = Color(hex: "D8F3E7")
    static let charcoal  = Color(hex: "1F242A")   // primary dark (primary button, logo)
    static let charcoal2 = Color(hex: "2B3138")   // secondary dark

    /// The accent for text and small elements — a readable deep mint on light, bright mint on dark.
    static let accent = Color(light: Color(hex: "2F8F6A"), dark: mint)

    // MARK: Semantic
    static let success = Color(hex: "4CAF7D")
    static let warning = Color(hex: "F4B942")
    static let error   = Color(hex: "E05C5C")

    // MARK: Surfaces (theme-aware)
    static let bg            = Color(light: Color(hex: "F8F9FB"), dark: Color(hex: "0F1115"))
    static let surface       = Color(light: .white,               dark: Color(hex: "171A20"))
    static let card          = Color(light: .white,               dark: Color(hex: "1F232B"))
    static let border        = Color(light: Color(hex: "E7EAF0"), dark: Color(hex: "2D333C"))
    static let textPrimary   = Color(light: Color(hex: "1B1F24"), dark: Color(hex: "F5F7FA"))
    static let textSecondary = Color(light: Color(hex: "5F6773"), dark: Color(hex: "A2AAB8"))

    // MARK: Legacy aliases — old names now resolve to the brand, so existing views rebrand at once.
    static let indigo = accent          // was #4F46E5 → the brand accent
    static let teal = mint              // was #14B8A6 → mint
    static let ink = charcoal

    /// Primary fill: charcoal (white text stays readable), matching the brand's primary button.
    static let accentGradient = LinearGradient(
        colors: [charcoal, charcoal2], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Mint fill for accent surfaces / hovers.
    static let mintGradient = LinearGradient(
        colors: [mint, mintLight], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Distinct, stable hue per speaker key (S1 teal, S2 indigo, then rotating).
    /// Shades are picked for ≥4.5:1 contrast on the app's light surfaces — speaker names
    /// render as small bold text, so brighter brand tints don't hold up.
    static func speakerColor(_ key: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.05, green: 0.46, blue: 0.43),       // S1 deep teal — me
            indigo,                                          // S2 #4F46E5
            Color(red: 0.76, green: 0.25, blue: 0.05),       // S3 burnt orange
            Color(red: 0.64, green: 0.11, blue: 0.66),       // S4 magenta
            Color(red: 0.01, green: 0.41, blue: 0.63),       // S5 deep sky
            Color(red: 0.30, green: 0.49, blue: 0.06),       // S6 olive
        ]
        let number = Int(key.dropFirst()) ?? 1
        return palette[(number - 1) % palette.count]
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension Theme {
    // Corner radii (brand spec).
    static let cardRadius: CGFloat = 20
    static let buttonRadius: CGFloat = 14
    static let inputRadius: CGFloat = 14
    static let dialogRadius: CGFloat = 24
    static let navRadius: CGFloat = 18
    static let hairline = border
}

/// The SK Note Taker type scale: a small, deliberate ramp used on every screen in place of
/// ad-hoc `.system(size:)` calls, so headings, titles, body, and captions stay consistent.
/// The common tiers (body/callout/caption/footnote) keep their existing sizes; only the scattered
/// outliers are normalized onto the ramp.
extension Font {
    static let skHero          = Font.system(size: 22, weight: .bold, design: .rounded)     // empty-state + detail titles
    static let skTitle         = Font.system(size: 18, weight: .bold)                        // large section / sheet titles
    static let skHeadline      = Font.system(size: 15, weight: .semibold)                    // prominent headers
    static let skSection       = Font.system(size: 14, weight: .semibold)                    // card titles
    static let skSubtitle      = Font.system(size: 13, weight: .semibold)                    // row / event titles
    static let skBody          = Font.system(size: 13)                                       // body, transcript, summary
    static let skCallout       = Font.system(size: 12)                                       // secondary body
    static let skLabel         = Font.system(size: 12, weight: .semibold)                    // small emphasized labels / buttons
    static let skCaption       = Font.system(size: 11, weight: .medium)                      // metadata, tags
    static let skCaptionStrong = Font.system(size: 11, weight: .semibold)                    // emphasized captions
    static let skFootnote      = Font.system(size: 10)                                       // tertiary hints
    static let skFootnoteStrong = Font.system(size: 10, weight: .semibold)                   // emphasized tertiary
    static let skBadge         = Font.system(size: 9, weight: .bold)                         // micro badges / chevrons
    static let skMono          = Font.system(size: 13, weight: .medium, design: .monospaced) // timers
    static let skMonoSmall     = Font.system(size: 11, design: .monospaced)                  // small mono (paths)
}

extension View {
    /// The standard card surface used across every screen: a fill appropriate to the context,
    /// continuous corners at the shared radius, a hairline border, and a subtle lift shadow.
    /// Pass a tinted fill for cards on plain backgrounds; the default suits the detail rail.
    func skCard<S: ShapeStyle>(_ fill: S, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 6)   // soft, per brand spec
    }

    func skCard(padding: CGFloat = 14) -> some View { skCard(.background, padding: padding) }
}

extension Color {
    /// A colour that resolves differently in light and dark appearances.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    /// Parse a Google calendar colour like "#a4bdfc". Falls back to grey on a bad string.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        var value: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&value) else {
            self = .gray; return
        }
        self = Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

/// The logo mark: rounded gradient square with soundwave bars (mirrors assets/logo.svg).
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Theme.accentGradient)
            HStack(spacing: size * 0.09) {
                bar(0.32); bar(0.55); bar(0.80); bar(0.45); bar(0.62)
            }
        }
        .frame(width: size, height: size)
    }

    private func bar(_ scale: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.075, height: size * scale * 0.72)
    }
}

struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("SK Note Taker")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("AI meeting notes")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
