import SwiftUI

// MARK: - Hero panel

/// Adaptive welcome surface shared with the grouped content throughout the app.
struct HeroPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .lbGroupedSurface()
    }
}

// MARK: - HUD capsule

extension View {
    /// The one floating-surface chrome: material fill, hairline border, HUD
    /// radius, soft shadow. Shared by the dictation HUD, the audio-source
    /// banner, and the recording pill so every floating capsule reads as one
    /// family. Pass `shadowed: false` inside borderless NSPanels sized
    /// exactly to their content — a SwiftUI shadow would clip at the panel
    /// edge there.
    func hudCapsule(radius: CGFloat = Brand.Radius.hud, shadowed: Bool = true) -> some View {
        background(.regularMaterial,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(shadowed ? 0.12 : 0), radius: shadowed ? 6 : 0, y: shadowed ? 3 : 0)
    }
}
