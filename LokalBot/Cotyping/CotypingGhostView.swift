import AppKit
import CoreText

/// Draws a suggestion's lines at exact baselines. Plain AppKit drawing keeps
/// the ghost on the field's own baseline and avoids a SwiftUI layout pass on
/// every keystroke. The word the next accept takes is drawn a little stronger
/// than the rest, so it is clear what Tab will insert.
final class CotypingGhostTextView: NSView {
    struct Line: Equatable {
        let text: String
        /// Where `text` starts in the displayed suggestion, in characters.
        let offset: Int
        /// The baseline's leading end in view coordinates (its right end for
        /// right-to-left text).
        let origin: CGPoint
    }

    struct Content: Equatable {
        var lines: [Line]
        var font: NSFont
        /// Characters from the start of the suggestion the next accept takes.
        var emphasisLength: Int
        var color: NSColor
        var emphasisColor: NSColor
        var isRightToLeft = false
        /// Popup placement draws its own background.
        var showsChrome = false
    }

    var content: Content? {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        if content.showsChrome {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        for line in content.lines {
            let ctLine = CTLineCreateWithAttributedString(attributed(line, content: content))
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            context.textPosition = CGPoint(
                x: content.isRightToLeft ? line.origin.x - width : line.origin.x,
                y: line.origin.y)
            CTLineDraw(ctLine, context)
        }
    }

    private func attributed(_ line: Line, content: Content) -> NSAttributedString {
        let text = NSMutableAttributedString(string: line.text, attributes: [
            .font: content.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): content.color.cgColor,
        ])
        let emphasized = min(line.text.count, max(0, content.emphasisLength - line.offset))
        if emphasized > 0 {
            let end = line.text.index(line.text.startIndex, offsetBy: emphasized)
            text.addAttribute(
                NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                value: content.emphasisColor.cgColor,
                range: NSRange(line.text.startIndex..<end, in: line.text))
        }
        return text
    }
}

nonisolated enum CotypingGhostHighlight {
    /// The part of `text` the next accept keypress takes, with the user's
    /// word-or-phrase and punctuation settings.
    static func acceptancePrefix(
        in text: String,
        granularity: CotypingAcceptGranularity = .word,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !text.isEmpty else { return "" }
        let chunk = switch granularity {
        case .word:
            CotypingAcceptanceChunker.nextWord(in: text, autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation)
        case .phrase:
            CotypingAcceptanceChunker.nextPhrase(in: text, autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation)
        }
        return text.hasPrefix(chunk) ? chunk : ""
    }
}
