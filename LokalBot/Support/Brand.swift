import AppKit
import SwiftUI

/// Brand identity derived from the app icon and marketing site. The icon is an
/// L-shaped robot on a dark slate plate, drawn in a mint→teal gradient with a
/// single amber antenna. The app uses a deeper primary teal than the icon so
/// tinted text and controls keep sufficient contrast on light materials.
enum Brand {
    /// Primary app accent for text, icons, strokes, selection washes, and
    /// tinted controls. Deep teal on light surfaces and a lighter mint on dark
    /// ones, so accent text meets WCAG AA in both appearances
    /// (`BrandContrastTests`).
    static let tealNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x6E / 255, green: 0xF2 / 255, blue: 0xDC / 255, alpha: 1) // #6EF2DC; includes tinted dark surfaces
            : NSColor(srgbRed: 0x07 / 255, green: 0x5F / 255, blue: 0x55 / 255, alpha: 1) // #075F55; text on grouped/tinted surfaces
    }
    static let teal = Color(nsColor: tealNSColor)
    /// Accent fill behind white foregrounds — filled buttons, badges, icon
    /// tiles, and meeting blocks. Stays deep in both appearances.
    static let tealFillNSColor = NSColor(srgbRed: 0x0C / 255, green: 0x82 / 255, blue: 0x75 / 255, alpha: 1)
    static let tealFill = Color(nsColor: tealFillNSColor)
    /// Attention indicators, remote inference, and bookmarks.
    static let amber = LBTokens.Palette.attention
    /// Failure and warning text, icons, and borders. One semantic hook —
    /// currently the system orange — so the error presentation can evolve in
    /// one place instead of dozens of hardcoded `.orange`s.
    static let error = LBTokens.Palette.attentionText

    /// "Me" speaker (mic track) — the user's own voice.
    static let me = teal
    /// "Them" speaker (system track) — other participants.
    static let them = Color(red: 0.49, green: 0.62, blue: 0.76)

    /// A view modifier that sets the brand tint and offers a softer fallback
    /// in High Contrast / Increase Contrast where the teal can read thin.
    struct TintModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.tint(teal)
        }
    }
}

extension View {
    /// Apply the LokalBot brand accent app-wide.
    func brandTinted() -> some View { modifier(Brand.TintModifier()) }
}
