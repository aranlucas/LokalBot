import AppKit
import SwiftUI

/// The width a split pane keeps once it has settled. SwiftUI can re-divide an
/// HSplitView when the sibling pane's content changes — the Timeline swapping
/// its day column for a selection's details did, widening the sessions rail to
/// its maximum. Only a divider drag chooses a new width; any other resize is
/// put back.
struct HeldPaneWidth {
    private(set) var width: CGFloat?
    /// A width the split clamped a restore to (the window is too narrow).
    /// Retrying at that same width would loop.
    private var unreachableWidth: CGFloat?
    private static let tolerance: CGFloat = 1

    mutating func settle(at width: CGFloat) {
        self.width = width
        unreachableWidth = nil
    }

    /// The width to restore after the pane was resized, or nil to leave it.
    mutating func resized(to paneWidth: CGFloat, byUser: Bool) -> CGFloat? {
        if byUser {
            settle(at: paneWidth)
            return nil
        }
        guard let width, abs(paneWidth - width) > Self.tolerance else { return nil }
        if let unreachableWidth, abs(paneWidth - unreachableWidth) <= Self.tolerance { return nil }
        return width
    }

    mutating func restoreFailed(at paneWidth: CGFloat) {
        unreachableWidth = paneWidth
    }
}

/// Suppresses repeated configuration work while preserving attachment/layout retries.
struct SplitPaneRefreshState {
    struct Configuration: Equatable {
        var label: String
        var autosaveName: String?
        var initialWidth: CGFloat?
    }
    private var configuration: Configuration?

    mutating func update(_ next: Configuration) -> Bool {
        guard configuration != next else { return false }
        configuration = next
        return true
    }
}

/// Geometry has its own cache so accessibility label updates can never mark a
/// divider configuration dirty.
struct SplitPaneGeometryRefreshState {
    struct Configuration: Equatable {
        var autosaveName: String?
        var initialWidth: CGFloat?
    }

    private var configuration: Configuration?

    mutating func update(_ next: Configuration) -> Bool {
        guard configuration != next else { return false }
        configuration = next
        return true
    }
}

/// Owns divider geometry and autosave restoration for a native split pane.
/// Accessibility is deliberately handled by a separate representable below;
/// changing a label must never cause geometry work or a divider correction.
private struct SplitPaneGeometry: NSViewRepresentable {
    var autosaveName: String?
    var initialWidth: CGFloat?

    func makeNSView(context: Context) -> PaneAnchor {
        let anchor = PaneAnchor()
        anchor.setAccessibilityElement(false)
        anchor.autosaveName = autosaveName
        anchor.initialWidth = initialWidth
        return anchor
    }

    func updateNSView(_ anchor: PaneAnchor, context: Context) {
        guard anchor.refreshState.update(.init(autosaveName: autosaveName,
                                               initialWidth: initialWidth)) else { return }
        anchor.autosaveName = autosaveName
        anchor.initialWidth = initialWidth
    }

    final class PaneAnchor: NSView {
        var refreshState = SplitPaneGeometryRefreshState()
        var autosaveName: String?
        var initialWidth: CGFloat?
        /// Cleared once the pane has its opening width, or once a divider
        /// position the user saved earlier has been restored instead.
        private var initialWidthPending = true
        /// SwiftUI can even out the split after the first placement, for
        /// example when a window is resized right after opening. Placement is
        /// retried until the pane measures its opening width, a bounded number
        /// of times so it never fights a divider the user is dragging.
        private var initialWidthAttempts = 0
        private static let maximumInitialWidthAttempts = 12
        private var held = HeldPaneWidth()
        private weak var observedSplit: NSSplitView?
        private var resizeObserver: NSObjectProtocol?
        private var restoringHeldWidth = false
        private var configuringGeometry = false

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configurePaneGeometry()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configurePaneGeometry()
        }

        /// The split can attach before it has its final width. Keep retrying
        /// as the pane lays out until the opening width lands, instead of
        /// leaving (and saving) HSplitView's even split.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if initialWidth != nil, initialWidthPending { configurePaneGeometry() }
        }

        override func layout() {
            super.layout()
            configurePaneGeometry()
        }

        /// Restore sizing during native layout, before the window draws. Doing
        /// this only in the queued accessibility callback shows the even split
        /// for a frame and then visibly moves the divider and wraps the content.
        private func configurePaneGeometry() {
            guard !configuringGeometry, window != nil else { return }
            configuringGeometry = true
            defer { configuringGeometry = false }
            var child: NSView = self
            while let parent = child.superview {
                if let split = parent as? NSSplitView {
                    guard child.frame.width > 0, split.bounds.width > 0 else { return }
                    if let name = autosaveName, split.autosaveName != name {
                        if Self.hasSavedFrames(name) { initialWidthPending = false }
                        split.autosaveName = name
                    }
                    applyInitialWidth(of: child, in: split)
                    return
                }
                child = parent
            }
        }

        /// HSplitView splits two flexible panes evenly. A pane with an opening
        /// width gets it once, and then holds its width while the window
        /// resizes so the sibling pane absorbs the change instead.
        private func applyInitialWidth(of pane: NSView, in split: NSSplitView) {
            guard let width = initialWidth, split.isVertical, split.arrangedSubviews.count == 2,
                  let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }) else { return }
            observeResizes(of: split, pane: pane)
            // HSplitView's split view belongs to a split view controller, which
            // owns holding priorities through its items.
            let holding = NSLayoutConstraint.Priority.defaultLow + 10
            if let controller = split.delegate as? NSSplitViewController {
                if controller.splitViewItems.indices.contains(index),
                   controller.splitViewItems[index].holdingPriority != holding {
                    controller.splitViewItems[index].holdingPriority = holding
                }
            } else if split.holdingPriorityForSubview(at: index) != holding {
                split.setHoldingPriority(holding, forSubviewAt: index)
            }
            guard initialWidthPending else {
                // A restored divider position counts as settled too.
                if held.width == nil { held.settle(at: pane.frame.width) }
                return
            }
            guard split.bounds.width > width + split.dividerThickness else { return }
            if abs(pane.frame.width - width) <= 1 || initialWidthAttempts >= Self.maximumInitialWidthAttempts {
                initialWidthPending = false
                held.settle(at: pane.frame.width)
                return
            }
            initialWidthAttempts += 1
            let position = index == 0 ? width : split.bounds.width - width - split.dividerThickness
            split.setPosition(position, ofDividerAt: 0)
        }

        /// NSSplitView names the divider in the notification only when the
        /// user dragged it; every other resize is a re-division to undo.
        private func observeResizes(of split: NSSplitView, pane: NSView) {
            guard observedSplit !== split else { return }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            observedSplit = split
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
            ) { [weak self, weak pane] note in
                let byUser = note.userInfo?["NSSplitViewDividerIndex"] != nil
                MainActor.assumeIsolated { self?.splitDidResize(pane: pane, byUser: byUser) }
            }
        }

        private func splitDidResize(pane: NSView?, byUser: Bool) {
            guard let pane, let split = observedSplit, !initialWidthPending, !restoringHeldWidth,
                  let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }),
                  let target = held.resized(to: pane.frame.width, byUser: byUser) else { return }
            restoringHeldWidth = true
            defer { restoringHeldWidth = false }
            let position = index == 0 ? target : split.bounds.width - target - split.dividerThickness
            split.setPosition(position, ofDividerAt: 0)
            if abs(pane.frame.width - target) > 1 { held.restoreFailed(at: pane.frame.width) }
        }

        private static func hasSavedFrames(_ autosaveName: String) -> Bool {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
        }
    }
}

/// Labels the native split item's accessibility group without touching its
/// frame, autosave state, or holding priorities.
private struct SplitPaneAccessibility: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> AccessibilityAnchor {
        let anchor = AccessibilityAnchor()
        anchor.setAccessibilityElement(false)
        anchor.label = label
        return anchor
    }

    func updateNSView(_ anchor: AccessibilityAnchor, context: Context) {
        guard anchor.label != label else { return }
        anchor.label = label
        anchor.updateLabel()
    }

    final class AccessibilityAnchor: NSView {
        var label = ""
        private var updatePending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateLabel()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateLabel()
        }

        func updateLabel() {
            guard !updatePending else { return }
            updatePending = true
            // SwiftUI can attach the background before the native split item
            // exists. Retry after attachment, without scheduling layout work.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                guard self.window != nil else { return }
                var child: NSView = self
                while let parent = child.superview {
                    if let split = parent as? NSSplitView {
                        child.setAccessibilityLabel(self.label)
                        let panes: [any NSAccessibilityProtocol] = (split.accessibilityChildren() ?? [])
                            .compactMap { $0 as? any NSAccessibilityProtocol }
                            .filter { $0.accessibilityRole() == .group }
                        if panes.count == split.arrangedSubviews.count,
                           let index = split.arrangedSubviews.firstIndex(where: { $0 === child }) {
                            panes[index].setAccessibilityLabel(self.label)
                            panes[index].setAccessibilityTitle(self.label)
                        }
                        return
                    }
                    child = parent
                }
            }
        }
    }
}

extension View {
    /// Names a split pane for VoiceOver. `autosaveName` gives the split its own
    /// saved divider position; `initialWidth` sets this pane's width the first
    /// time the split appears without one.
    func splitPaneAccessibilityLabel(
        _ label: String,
        autosaveName: String? = nil,
        initialWidth: CGFloat? = nil
    ) -> some View {
        background {
            SplitPaneGeometry(autosaveName: autosaveName, initialWidth: initialWidth)
        }
        .background {
            SplitPaneAccessibility(label: label)
        }
    }
}
