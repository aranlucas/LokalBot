import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// From macOS 26 an `HSplitView` in NavigationSplitView's detail counted the
/// sidebar twice in the window's minimum width, so Meetings could not shrink
/// below about 1,100 pt. Hosts the main window's structure in an off-screen
/// window, with no autosaved split, and checks how far it shrinks.
@MainActor
final class DetailSplitMinimumWidthTests: XCTestCase {
    func testMainWindowSplitShrinksToSidebarPlusPanes() throws {
        let panes = [LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth]
        let root = NavigationSplitView {
            List { Text("Meetings") }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: LBTokens.Metric.sidebarMinWidth,
                                                ideal: LBTokens.Metric.sidebarWidth, max: 260)
        } detail: {
            HSplitView {
                Color.clear.frame(minWidth: panes[0], idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                Color.clear.frame(minWidth: panes[1], maxWidth: .infinity, maxHeight: .infinity)
            }
            .detailSplitMinimumWidth(panes)
        }
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        defer { window.close() }
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        settle()
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 700, height: 600)), display: false)
        settle()

        let panesAndDivider = panes.reduce(0, +) + 1
        XCTAssertLessThanOrEqual(window.frame.width, LBTokens.Metric.sidebarWidth + panesAndDivider + 1,
                                 "The window must shrink to the sidebar plus the split's panes")
        func splits(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits(in: $0) }
        }
        let inner = try XCTUnwrap(splits(in: host).last)
        XCTAssertEqual(inner.arrangedSubviews.count, 2)
        XCTAssertGreaterThanOrEqual(inner.arrangedSubviews[0].frame.width, panes[0] - 1)
        XCTAssertGreaterThanOrEqual(inner.arrangedSubviews[1].frame.width, panes[1] - 1,
                                    "Neither pane may be squeezed below its minimum")
    }
}
