import SwiftUI
import AppKit
import CoreText

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
    /// Hero moments (home CTA, branded surfaces): charcoal deepening into a mint-tinged charcoal,
    /// so the primary button reads bolder than a flat fill without leaving the brand.
    static let heroGradient = LinearGradient(
        colors: [charcoal, Color(hex: "1E3A2D")], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Semantic states (the only place these meanings get a color)
    /// Recording / live indicator — brand-tuned red, brighter in dark so it doesn't vibrate on charcoal.
    static let recording = Color(light: Color(hex: "D6453F"), dark: Color(hex: "E86B63"))
    /// Starred items — tuned amber instead of system yellow.
    static let star = Color(light: Color(hex: "E9A23B"), dark: Color(hex: "F2B84B"))
    /// Row/selection highlight and drag-over target fills, tuned per scheme (the light-mode
    /// opacities disappeared on charcoal).
    static let selection = Color(light: mint.opacity(0.18), dark: mint.opacity(0.24))
    static let dropTarget = Color(light: mint.opacity(0.32), dark: mint.opacity(0.38))
    /// Elevation shadow for cards: soft in light, stronger in dark (a 6% black shadow is
    /// invisible on near-black, so dark relies on the hairline border plus a deeper shadow).
    static let cardShadow = Color(light: .black.opacity(0.06), dark: .black.opacity(0.45))

    /// Brand-derived folder hues (stable per project, seeded from the folder id).
    static let folderPalette: [Color] = [
        accent,
        Color(light: Color(hex: "E9A23B"), dark: Color(hex: "F2B84B")),   // amber
        Color(light: Color(hex: "D2694A"), dark: Color(hex: "EE9273")),   // coral
        Color(light: Color(hex: "3D7FB8"), dark: Color(hex: "74B3E8")),   // sky
        Color(light: Color(hex: "7D63C4"), dark: Color(hex: "A990EE")),   // violet
        Color(light: Color(hex: "6D8A3A"), dark: Color(hex: "A3C46A")),   // olive
    ]

    /// Stable colour per project. Seeded from the id string (UUID hashValue is per-run), so a
    /// project keeps its colour across launches; shared by the sidebar and the command palette.
    static func folderColor(for id: UUID) -> Color {
        let seed = id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return folderPalette[seed % folderPalette.count]
    }

    /// Distinct, stable hue per speaker key (S1 teal, S2 accent, then rotating).
    /// Each entry is appearance-aware: the light shades hold >=4.5:1 on white surfaces (speaker
    /// names render as small bold text), the dark shades are brightened for charcoal.
    static func speakerColor(_ key: String) -> Color {
        let palette: [Color] = [
            Color(light: Color(red: 0.05, green: 0.46, blue: 0.43),
                  dark: Color(red: 0.36, green: 0.80, blue: 0.75)),      // S1 teal — me
            accent,                                                       // S2 brand accent
            Color(light: Color(red: 0.76, green: 0.25, blue: 0.05),
                  dark: Color(red: 0.95, green: 0.58, blue: 0.38)),      // S3 burnt orange
            Color(light: Color(red: 0.64, green: 0.11, blue: 0.66),
                  dark: Color(red: 0.87, green: 0.56, blue: 0.90)),      // S4 magenta
            Color(light: Color(red: 0.01, green: 0.41, blue: 0.63),
                  dark: Color(red: 0.45, green: 0.74, blue: 0.95)),      // S5 sky
            Color(light: Color(red: 0.30, green: 0.49, blue: 0.06),
                  dark: Color(red: 0.66, green: 0.81, blue: 0.40)),      // S6 olive
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

    /// The app's motion vocabulary — every withAnimation/.animation call site uses one of these
    /// four tokens, never an inline curve, so timing stays coherent across screens. All of them
    /// collapse to a near-instant fade when the user has Reduce Motion on.
    enum Motion {
        private static var reduce: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        /// Hovers, toggles, small state flips.
        static var snap: Animation { reduce ? .linear(duration: 0.01) : .easeOut(duration: 0.15) }
        /// Tab/content changes, expand/collapse, selection moves.
        static var standard: Animation { reduce ? .linear(duration: 0.01) : .easeInOut(duration: 0.22) }
        /// Buttons, cards, the command palette — anything that should feel physical.
        static var spring: Animation {
            reduce ? .linear(duration: 0.01) : .spring(response: 0.35, dampingFraction: 0.75)
        }
        /// Hero entrances and large surfaces.
        static var gentle: Animation { reduce ? .linear(duration: 0.01) : .easeInOut(duration: 0.4) }
    }
}

/// The SK Note Taker type scale: a small, deliberate ramp used on every screen in place of
/// ad-hoc `.system(size:)` calls, so headings, titles, body, and captions stay consistent.
/// The common tiers (body/callout/caption/footnote) keep their existing sizes; only the scattered
/// outliers are normalized onto the ramp.
extension Font {
    // Brand pairing: headings in Plus Jakarta Sans, everything else in Inter (registered at launch).
    private static func jakarta(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom("Plus Jakarta Sans", size: size).weight(weight)
    }
    private static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }

    static let skDisplay       = jakarta(32, .bold)      // the home hero headline
    static let skBrand         = jakarta(16, .bold)      // the sidebar wordmark
    static let skHero          = jakarta(22, .bold)      // empty-state + detail titles
    static let skTitle         = jakarta(18, .bold)      // large section / sheet titles
    static let skHeadline      = jakarta(15, .semibold)  // prominent headers
    static let skSection       = inter(14, .semibold)    // card titles
    static let skSubtitle      = inter(13, .semibold)    // row / event titles
    static let skBody          = inter(13)               // body, transcript, summary
    static let skCallout       = inter(12)               // secondary body
    static let skLabel         = inter(12, .medium)      // small emphasized labels / buttons
    static let skCaption       = inter(11, .medium)      // metadata, tags
    static let skCaptionStrong = inter(11, .semibold)    // emphasized captions
    static let skFootnote      = inter(10)               // tertiary hints
    static let skFootnoteStrong = inter(10, .semibold)   // emphasized tertiary
    static let skBadge         = inter(9, .bold)         // micro badges / chevrons
    static let skMono          = Font.system(size: 13, weight: .medium, design: .monospaced) // timers stay monospaced
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
            .shadow(color: Theme.cardShadow, radius: 18, y: 6)   // soft in light, deep in dark
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
/// Bundled brand assets.
enum BrandAssets {
    /// The SK Note Taker logo mark (loaded once).
    static let logo: NSImage? = Bundle.module
        .url(forResource: "BrandLogo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

/// Registers the bundled brand fonts (Plus Jakarta Sans + Inter) so the type ramp can use them.
/// Call once at launch, before any view renders.
enum BrandFonts {
    static func register() {
        var urls: [URL] = []
        for sub in [nil, "Fonts"] as [String?] {
            if let found = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: sub) {
                urls += found
            }
        }
        if urls.isEmpty, let root = Bundle.module.resourceURL,
           let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "ttf" { urls.append(url) }
        }
        for url in Set(urls) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// The SK Note Taker logo mark, rendered as a rounded tile at any size.
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Theme.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .strokeBorder(Theme.hairline))
    }
}

struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("SK Note Taker")
                    .font(.skBrand)
                Text("AI meeting notes")
                    .font(.skFootnoteStrong)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
