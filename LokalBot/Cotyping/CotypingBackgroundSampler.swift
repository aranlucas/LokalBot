import AppKit
import ScreenCaptureKit

/// Samples the average luminance of the host pixels behind the cotyping caret,
/// reusing the same ScreenCaptureKit engine (and Screen Recording grant) as the
/// screenshot pipeline. `CGWindowListCreateImage` is unavailable on current
/// SDKs, so this is the supported way to read what's actually on screen.
///
/// The overlay panel sets `sharingType = .none`, so a capture never includes our
/// own ghost. Results are cached per app and light or dark mode: a field's
/// background rarely changes, and a fresh capture would recolor the ghost a
/// moment after it appears.
@MainActor
final class CotypingBackgroundSampler {
    private var cache: [String: (luminance: CGFloat, at: Date)] = [:]
    private static let cacheTTL: TimeInterval = 300

    /// A still-fresh luminance for `bundleID`, used to color the ghost instantly
    /// (no capture, no flash) for repeat suggestions in the same app.
    func cachedLuminance(forApp bundleID: String?) -> CGFloat? {
        guard let key = Self.key(bundleID), let hit = cache[key],
              Date().timeIntervalSince(hit.at) < Self.cacheTTL else { return nil }
        return hit.luminance
    }

    private static func key(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return bundleID + (dark ? "/dark" : "/light")
    }

    /// Capture the strip behind `caretRect` and return its average luminance
    /// (0…1), caching it for `bundleID`. `nil` when Screen Recording isn't
    /// authorized or the capture fails — the caller keeps its AX/appearance guess.
    func sampleLuminance(at caretRect: CGRect, forApp bundleID: String?) async -> CGFloat? {
        guard CGPreflightScreenCaptureAccess(),
              let luminance = await Self.captureLuminance(at: caretRect) else { return nil }
        if let key = Self.key(bundleID) { cache[key] = (luminance, Date()) }
        return luminance
    }

    private static func captureLuminance(at caretRect: CGRect) async -> CGFloat? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
        let center = CGPoint(x: caretRect.midX, y: caretRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let screenNumber = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = content.displays.first(where: { $0.displayID == screenNumber })
        else { return nil }

        // Global Cocoa (bottom-left) → the display's top-left point space, and
        // sample the strip to the right of the caret where the ghost draws.
        let source = CGRect(
            x: caretRect.minX - screen.frame.minX,
            y: screen.frame.maxY - caretRect.maxY,
            width: max(caretRect.width, 1) + 160,
            height: max(caretRect.height, 8))
        let aspect = source.width > 0 ? source.height / source.width : 0.25

        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = 32
        config.height = max(2, Int((32 * aspect).rounded()))  // match aspect → no letterbox
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config) else { return nil }
        return averageLuminance(of: image)
    }

    /// Mean Rec. 601 luminance of `image`, via a 1×1 downscale that averages it.
    nonisolated static func averageLuminance(of image: CGImage) -> CGFloat? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return 0.299 * CGFloat(pixel[0]) / 255
            + 0.587 * CGFloat(pixel[1]) / 255
            + 0.114 * CGFloat(pixel[2]) / 255
    }
}
