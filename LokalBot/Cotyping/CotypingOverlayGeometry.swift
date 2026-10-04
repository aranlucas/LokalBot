import CoreGraphics

/// Pure placement math for the ghost overlay, split out from `show()` so the
/// frame geometry is deterministic and unit-testable. All rects are in global
/// Cocoa (bottom-left origin) coordinates.
nonisolated enum CotypingOverlayGeometry {
    /// Gap between the caret and the popup / screen edges.
    static let gap: CGFloat = 2
    static let reanchorDriftTolerance: CGFloat = 6
    static let backwardDriftHoldWindowMilliseconds = 300

    /// CoTabby-style post-accept stability rule for inline ghosts. Hold small
    /// same-text drift, and briefly hold larger backward jumps because AX often
    /// publishes inserted text before its caret frames catch up.
    static func shouldHoldInlineReanchor(
        currentFrame: CGRect,
        targetFrame: CGRect,
        millisecondsSinceLastAcceptance: Int?,
        isRightToLeft: Bool = false
    ) -> Bool {
        let deltaY = targetFrame.origin.y - currentFrame.origin.y
        guard abs(deltaY) <= reanchorDriftTolerance else { return false }

        let deltaX = targetFrame.origin.x - currentFrame.origin.x
        if abs(deltaX) <= reanchorDriftTolerance {
            return true
        }
        let isBackward = isRightToLeft
            ? deltaX > reanchorDriftTolerance
            : deltaX < -reanchorDriftTolerance
        let insideHoldWindow = millisecondsSinceLastAcceptance
            .map { $0 <= backwardDriftHoldWindowMilliseconds } ?? false
        return isBackward && insideHoldWindow
    }

    /// Mirror (popup) frame: a chrome pill one line below the caret, flipped
    /// above when there is no room below. Used for mid-line carets where inline
    /// text would paint over the host's trailing characters.
    static func mirrorFrame(
        caret: CGRect, content: CGSize, visible: CGRect?
    ) -> CGRect {
        let width = max(content.width, 8)
        let height = max(content.height, 18)
        var x = min(caret.minX, (visible?.maxX ?? caret.minX) - width)
        if let visible { x = max(visible.minX + gap, x) }
        var y = caret.minY - height - gap
        if let visible, y < visible.minY { y = caret.maxY + gap }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
