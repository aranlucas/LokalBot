import AppKit

/// Derives an exact caret rect from an editable's text-run descendants when
/// both range- and marker-based caret geometry fail.
///
/// Chromium and Electron (measured in Chrome and Discord) return zero-size
/// rects for a collapsed caret from `AXBoundsForRange` *and* from
/// `AXBoundsForTextMarkerRange` on the selection, and they do not implement
/// the marker-extraction attributes that would let us widen the range. But
/// Blink still exposes every laid-out text run as an `AXStaticText` child
/// with a tight pixel frame — so when the caret sits at the end of the text,
/// the last run's trailing edge *is* the caret. Pure geometry over plain
/// values so it is unit-testable without AX.
nonisolated enum CotypingTextLeafCaret {
    struct Leaf {
        /// Top-left-origin AX display coordinates, like all raw AX frames.
        let frame: CGRect
        let text: String
    }

    /// Sanity band for a single text-run box height (points).
    private static let lineHeightBand: ClosedRange<CGFloat> = 4...64
    /// Slack for leaf-inside-element containment (borders, subpixel rounding).
    private static let containmentTolerance: CGFloat = 4
    /// A run's box is about 1.2 to 1.5 times its font size tall. Sizing the
    /// system font from the tall end keeps one line of text no wider than
    /// its box, give or take the page font's own widths.
    private static let runHeightPerPointSize: CGFloat = 1.5
    /// Text set that way and wider than this many times its box cannot be one
    /// line: the run wraps, its box spans several lines, and its trailing
    /// edge is the end of its widest line rather than the caret.
    private static let wrappedRunWidthRatio: CGFloat = 1.4

    /// Whether the caret sits at the end of the field's text, tolerating the
    /// trailing newline contenteditable editors keep in an "empty" tail
    /// (Discord's empty composer value is "\n"). A caret after that newline
    /// is on a new line, which no text run reaches. Cheap pre-check so
    /// callers can skip the AX subtree walk entirely for mid-text carets.
    static func caretIsAtTextEnd(fieldText: String, caretLocation: Int) -> Bool {
        caretLocation == trimmedUTF16Length(of: fieldText)
    }

    /// The caret rect in AX coordinates, or nil whenever the derivation would
    /// be a guess: the caret must be at the end of the text, and the last
    /// text run must be one line inside the element and match the tail of
    /// the text the field reports (a trailing emoji/mention run the field
    /// counts but the runs don't cover means the edge would be wrong —
    /// refuse instead). A run may stop short of spaces typed at the end of
    /// the text; the caret then sits that many spaces past the run.
    static func caretRect(
        elementFrame: CGRect,
        leaves: [Leaf],
        fieldText: String,
        caretLocation: Int,
        isRightToLeft: Bool
    ) -> CGRect? {
        guard caretIsAtTextEnd(fieldText: fieldText, caretLocation: caretLocation) else {
            return nil
        }
        guard let leaf = leaves.last(where: { !withoutTrailingSpaces(runText($0.text)).isEmpty }) else {
            return nil
        }
        let leafText = runText(leaf.text)
        let leafCore = withoutTrailingSpaces(leafText)
        let fieldTail = runText(fieldText)
        let missingSpaces = trailingSpaceCount(fieldTail) - trailingSpaceCount(leafText)
        guard missingSpaces >= 0, withoutTrailingSpaces(fieldTail).hasSuffix(leafCore) else { return nil }
        guard leaf.frame.width > 0,
              lineHeightBand.contains(leaf.frame.height),
              elementFrame
                  .insetBy(dx: -containmentTolerance, dy: -containmentTolerance)
                  .contains(leaf.frame),
              !isWrapped(leaf, text: leafCore) else {
            return nil
        }
        let gap = CGFloat(missingSpaces) * spaceWidth(in: leaf, text: leafCore)
        let x = isRightToLeft ? leaf.frame.minX - gap : leaf.frame.maxX + gap
        return CGRect(x: x, y: leaf.frame.minY, width: 1, height: leaf.frame.height)
    }

    /// Whether the run's text is too wide for one line of its box.
    private static func isWrapped(_ leaf: Leaf, text: String) -> Bool {
        let font = NSFont.systemFont(ofSize: leaf.frame.height / runHeightPerPointSize)
        return CotypingInlineGhostLayout.width(of: text, font: font) > leaf.frame.width * wrappedRunWidthRatio
    }

    /// One space in the run's font, scaled from the run's own width.
    private static func spaceWidth(in leaf: Leaf, text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let textWidth = CotypingInlineGhostLayout.width(of: text, font: font)
        guard textWidth > 0 else { return 0 }
        return leaf.frame.width * CotypingInlineGhostLayout.width(of: " ", font: font) / textWidth
    }

    /// The text without trailing line breaks, with no-break spaces (which
    /// web editors put where a typed space would collapse) as plain spaces.
    private static func runText(_ text: String) -> String {
        trimmedText(text).replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func trailingSpaceCount(_ text: String) -> Int {
        text.reversed().prefix { $0 == " " }.count
    }

    private static func withoutTrailingSpaces(_ text: String) -> String {
        String(text.dropLast(trailingSpaceCount(text)))
    }

    private static func trimmedText(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, CharacterSet.newlines.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func trimmedUTF16Length(of text: String) -> Int {
        (trimmedText(text) as NSString).length
    }
}
