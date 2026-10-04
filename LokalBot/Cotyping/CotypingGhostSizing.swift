import AppKit

/// Picks the font a suggestion is drawn in: the field's own font at its own
/// size when Accessibility reports one, so the ghost reads as the next
/// characters of the line, and otherwise the system font sized from the caret.
nonisolated enum CotypingGhostFontSizing {
    static let minimumPointSize: CGFloat = 8
    static let maximumPointSize: CGFloat = 48
    /// An estimated caret comes from the field frame and says little about the
    /// text, so a size guessed from it stays modest.
    static let maximumEstimatedPointSize: CGFloat = 16
    /// The system font's glyph box is about 1.2 times its point size, and web
    /// engines report a caret about as tall as that box.
    static let pointSizePerCaretHeight: CGFloat = 1 / 1.2

    static func font(for style: CotypingFieldStyle?, caretHeight: CGFloat, caretIsExact: Bool) -> NSFont {
        let size = min(maximumPointSize, max(minimumPointSize, pointSize(
            for: style, caretHeight: caretHeight, caretIsExact: caretIsExact)))
        return style?.fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static func pointSize(for style: CotypingFieldStyle?, caretHeight: CGFloat, caretIsExact: Bool) -> CGFloat {
        guard let reported = style?.fontPointSize, reported.isFinite, reported > 0 else {
            guard caretHeight.isFinite, caretHeight > 0 else { return NSFont.systemFontSize }
            let estimate = caretHeight * pointSizePerCaretHeight
            return caretIsExact ? estimate : min(estimate, maximumEstimatedPointSize)
        }
        // Zoomed pages and documents report the unzoomed size. Only a caret far
        // outside the font's own glyph box, beyond what line spacing explains,
        // is read as zoom.
        guard caretIsExact, caretHeight.isFinite, caretHeight > 0 else { return reported }
        let reference = style?.fontName.flatMap { NSFont(name: $0, size: reported) }
            ?? .systemFont(ofSize: reported)
        let glyphBox = reference.ascender - reference.descender
        guard glyphBox > 0 else { return reported }
        let ratio = caretHeight / glyphBox
        if ratio < 0.8 { return reported * ratio }
        if ratio > 2.4 { return reported * ratio / 1.2 }
        return reported
    }
}
