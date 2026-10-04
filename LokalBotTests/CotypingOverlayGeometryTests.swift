import AppKit
import XCTest
@testable import LokalBot

final class CotypingOverlayGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testInlineReanchorHoldsSmallSameTextDrift() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 124, y: 497, width: 100, height: 16),
            millisecondsSinceLastAcceptance: nil))
    }

    func testInlineReanchorHoldsBackwardJumpInsidePostAcceptWindow() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testInlineReanchorMirrorsBackwardJumpForRTL() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80,
            isRightToLeft: true))
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 80, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80,
            isRightToLeft: true))
    }

    func testInlineReanchorAllowsBackwardJumpAfterHoldWindow() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 450))
    }

    func testInlineReanchorAllowsForwardAndVerticalMoves() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 140, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 512, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testMirrorSitsBelowCaretAndFlipsAboveWhenNoRoom() {
        let below = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertEqual(below.maxY, 498, accuracy: 0.5)

        let nearBottom = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 5, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertGreaterThanOrEqual(nearBottom.minY, screen.minY)
    }

    func testMirrorLayoutWrapsLongSuggestionWithinBudget() {
        let font = NSFont.systemFont(ofSize: 13)
        let maxWidth: CGFloat = 140
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "Please confirm the renewal schedule before sending the customer update",
            font: font,
            maxWidth: maxWidth,
            maxLines: 4)

        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, maxWidth + 0.5)
        }
    }

    func testMirrorWrapPreservesWordsAfterOversizedToken() {
        let token = String(repeating: "W", count: 24)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: token + " contract approved", font: .systemFont(ofSize: 13), maxWidth: 80, maxLines: 20)
        XCTAssertEqual(lines.joined().replacingOccurrences(of: " ", with: ""), token + "contractapproved")
        XCTAssertFalse(lines.contains { $0.hasSuffix("...") })
        let clipped = CotypingGhostTextLayout.wrappedLines(
            text: token + " contract approved", font: .systemFont(ofSize: 13), maxWidth: 80, maxLines: 2)
        XCTAssertTrue(clipped.last?.hasSuffix("...") == true)
    }

    func testMirrorLayoutPreservesExplicitLineBoundaries() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "first line\nsecond line",
            font: font,
            maxWidth: 400,
            maxLines: 4)

        XCTAssertEqual(lines, ["first line", "second line"])
    }

    func testMirrorLayoutEllipsizesWhenRowsAreExhausted() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
            font: font,
            maxWidth: 90,
            maxLines: 2)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("..."))
    }

    func testAXRectConversionUsesContainingScreenFrame() {
        let converted = CotypingAXHelper.cocoaRect(
            fromAX: CGRect(x: 1500, y: -100, width: 2, height: 20),
            displayBounds: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            screenFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        XCTAssertEqual(converted.origin.x, 1500)
        XCTAssertEqual(converted.origin.y, 960)
        XCTAssertEqual(converted.width, 2)
        XCTAssertEqual(converted.height, 20)
    }

    // MARK: - Inline layout

    private let helvetica = NSFont(name: "Helvetica", size: 12)!

    func testTheGhostStartsExactlyAtTheCaret() {
        let caret = CGRect(x: 200, y: 500, width: 1, height: 14)
        let layout = CotypingInlineGhostLayout.make(
            text: "low up", font: helvetica, caretRect: caret,
            inputFrameRect: CGRect(x: 40, y: 480, width: 600, height: 40), visible: screen, isRightToLeft: false)
        XCTAssertEqual(layout.lines.map(\.text), ["low up"])
        XCTAssertEqual(layout.lines[0].origin.x, caret.maxX)
    }

    /// AppKit text reports a caret one default line tall; the ghost sits on
    /// that line's baseline, not on its center.
    func testAnAppKitCaretPutsTheGhostOnTheFieldBaseline() {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: helvetica)
        let baselineOffset = NSLayoutManager().defaultBaselineOffset(for: helvetica)
        let caret = CGRect(x: 200, y: 500, width: 0, height: lineHeight)
        XCTAssertEqual(
            CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: helvetica),
            caret.maxY - baselineOffset, accuracy: 0.01)
    }

    /// Web engines report about the glyph box; its center is the line's center.
    func testAWebCaretCentersTheGlyphBox() {
        let font = NSFont.systemFont(ofSize: 15)
        let caret = CGRect(x: 200, y: 500, width: 1, height: 24)
        let baseline = CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: font)
        XCTAssertEqual(baseline + (font.ascender + font.descender) / 2, caret.midY, accuracy: 0.01)
    }

    func testTheGhostUsesTheFieldsOwnFontAndSize() {
        let style = CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 12)
        let font = CotypingGhostFontSizing.font(for: style, caretHeight: 14, caretIsExact: true)
        XCTAssertEqual(font.fontName, "Helvetica")
        XCTAssertEqual(font.pointSize, 12)
    }

    func testAZoomedFieldScalesTheReportedSize() {
        let style = CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 12)
        XCTAssertEqual(CotypingGhostFontSizing.pointSize(for: style, caretHeight: 6, caretIsExact: true), 6, accuracy: 0.01)
        XCTAssertEqual(CotypingGhostFontSizing.pointSize(for: style, caretHeight: 6, caretIsExact: false), 12)
    }

    func testWithoutAReportedSizeTheCaretSizesTheSystemFont() {
        XCTAssertEqual(CotypingGhostFontSizing.pointSize(for: nil, caretHeight: 18, caretIsExact: true), 15, accuracy: 0.01)
        XCTAssertEqual(
            CotypingGhostFontSizing.pointSize(for: nil, caretHeight: 40, caretIsExact: false),
            CotypingGhostFontSizing.maximumEstimatedPointSize)
        XCTAssertEqual(CotypingGhostFontSizing.font(for: nil, caretHeight: 2, caretIsExact: true).pointSize,
                       CotypingGhostFontSizing.minimumPointSize)
    }

    func testWrappedLinesLineUpWithTheFieldsText() {
        let input = CGRect(x: 40, y: 480, width: 300, height: 60)
        let typed = "Hello there, thanks for"
        let textEdge: CGFloat = 46
        let caret = CGRect(
            x: textEdge + CotypingInlineGhostLayout.width(of: typed, font: helvetica), y: 520, width: 0, height: 14)
        let layout = CotypingInlineGhostLayout.make(
            text: " the quick follow up on the renewal timing and the customer update",
            font: helvetica, caretRect: caret, inputFrameRect: input,
            precedingLine: "Earlier paragraph.\n" + typed, visible: screen, isRightToLeft: false)

        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertEqual(layout.lines[0].origin.x, caret.maxX)
        XCTAssertTrue(layout.lines[0].text.hasPrefix(" the"))
        for line in layout.lines.dropFirst() {
            XCTAssertEqual(line.origin.x, textEdge, accuracy: 0.01)
            XCTAssertFalse(line.text.hasPrefix(" "))
            XCTAssertLessThanOrEqual(line.origin.x + line.width, input.maxX - CotypingInlineGhostLayout.fieldInset + 0.5)
        }
        let pitch = CotypingInlineGhostLayout.linePitch(caretRect: caret, font: helvetica)
        XCTAssertEqual(layout.lines[0].origin.y - layout.lines[1].origin.y, pitch, accuracy: 0.01)
        // Every character is drawn once, in order.
        let drawn = layout.lines.map(\.text).joined(separator: " ")
        XCTAssertEqual(drawn, " the quick follow up on the renewal timing and the customer update")
    }

    func testAWrappedParagraphFallsBackToTheFieldInset() {
        let input = CGRect(x: 40, y: 480, width: 200, height: 60)
        let caret = CGRect(x: 210, y: 520, width: 0, height: 14)
        let layout = CotypingInlineGhostLayout.make(
            text: " and then some more words here", font: helvetica, caretRect: caret, inputFrameRect: input,
            precedingLine: String(repeating: "a long paragraph that already wrapped ", count: 3),
            visible: screen, isRightToLeft: false)
        XCTAssertEqual(layout.lines.last?.origin.x, input.minX + CotypingInlineGhostLayout.fieldInset)
    }

    func testAWordThatDoesNotFitStartsOnTheNextLine() {
        let input = CGRect(x: 40, y: 480, width: 180, height: 60)
        let caret = CGRect(x: 205, y: 520, width: 0, height: 14)
        let layout = CotypingInlineGhostLayout.make(
            text: " confirm renewal", font: helvetica, caretRect: caret, inputFrameRect: input,
            visible: screen, isRightToLeft: false)
        XCTAssertEqual(layout.lines.first?.text, "confirm renewal")
        XCTAssertEqual(layout.lines.first?.offset, 1)
        XCTAssertLessThan(layout.lines[0].origin.y, CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: helvetica))
    }

    func testRightToLeftTextRunsFromTheCaretTowardTheLeft() {
        let input = CGRect(x: 40, y: 480, width: 260, height: 60)
        let caret = CGRect(x: 158, y: 520, width: 1, height: 14)
        let word = "\u{05d0}\u{05d1}\u{05d2} \u{05d3}\u{05d4}\u{05d5}"
        let layout = CotypingInlineGhostLayout.make(
            text: Array(repeating: word, count: 6).joined(separator: " "), font: helvetica, caretRect: caret,
            inputFrameRect: input, visible: screen, isRightToLeft: true)
        XCTAssertEqual(layout.lines[0].origin.x, caret.minX)
        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertGreaterThanOrEqual(layout.lines[0].origin.x - layout.lines[0].width, input.minX + 7.5)
        XCTAssertEqual(layout.lines[1].origin.x, input.maxX - CotypingInlineGhostLayout.fieldInset)
    }

    /// A top-up appends words; words already on screen keep their places.
    func testAppendingWordsNeverMovesWordsAlreadyShown() {
        let input = CGRect(x: 40, y: 480, width: 260, height: 60)
        let caret = CGRect(x: 200, y: 520, width: 0, height: 14)
        func layout(_ text: String) -> CotypingInlineGhostLayout {
            .make(text: text, font: helvetica, caretRect: caret, inputFrameRect: input,
                  visible: screen, isRightToLeft: false)
        }
        let before = layout(" follow up on")
        let after = layout(" follow up on the renewal timing")
        for (shown, extended) in zip(before.lines, after.lines) {
            XCTAssertEqual(extended.origin, shown.origin)
            XCTAssertTrue(extended.text.hasPrefix(shown.text))
        }
    }

    func testDisplayTextKeepsALeadingSpaceAndCollapsesRuns() {
        XCTAssertEqual(CotypingInlineGhostLayout.displayText("  up   on\tthis"), " up on this")
        XCTAssertEqual(CotypingInlineGhostLayout.displayText("done\n next"), "done\n next")
        XCTAssertGreaterThan(CotypingInlineGhostLayout.width(of: " up", font: helvetica),
                             CotypingInlineGhostLayout.width(of: "up", font: helvetica))
    }
}

/// Draws the ghost view offscreen and finds where its ink lands.
@MainActor
final class CotypingGhostTextViewTests: XCTestCase {
    private func inkRows(_ content: CotypingGhostTextView.Content, size: CGSize) throws -> (top: Int, bottom: Int, left: Int) {
        let view = CotypingGhostTextView(frame: CGRect(origin: .zero, size: size))
        view.content = content
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Bitmap rows count down from the top; view points count up.
        let scale = Double(rep.pixelsHigh) / size.height
        var highest = Int.min, lowest = Int.max, left = Int.max
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                let pointY = Int((Double(rep.pixelsHigh - y) / scale).rounded(.down))
                highest = max(highest, pointY)
                lowest = min(lowest, pointY)
                left = min(left, Int(Double(x) / scale))
            }
        }
        XCTAssertNotEqual(lowest, Int.max, "nothing was drawn")
        return (highest, lowest, left)
    }

    /// "HELLO" has no descenders, so its ink starts on the baseline and rises
    /// to about the cap height, beginning at the line's origin.
    func testTheGhostIsDrawnOnTheRequestedBaseline() throws {
        let font = NSFont(name: "Helvetica", size: 20)!
        let content = CotypingGhostTextView.Content(
            lines: [.init(text: "HELLO", offset: 0, origin: CGPoint(x: 10, y: 12))],
            font: font, emphasisLength: 0, color: .black, emphasisColor: .black)
        let ink = try inkRows(content, size: CGSize(width: 120, height: 40))
        XCTAssertEqual(ink.bottom, 12, accuracy: 1)
        XCTAssertEqual(ink.top, 12 + Int(font.capHeight), accuracy: 2)
        XCTAssertEqual(ink.left, 10, accuracy: 2)
    }
}
