import AppKit
import SwiftUI

/// Sizes a SwiftUI view the way a popover does: AppKit lays it out and reports the size it asks for
/// (ported from ClaudeCockpit).
///
/// A `ScrollView` has no intrinsic height: inside a `MenuBarExtra(.window)` the popover then asks for a
/// handful of points, and only a concrete `height` fixes that. SwiftUI cannot measure that height from the
/// inside (the scroll view proposes zero to its content during the sizing pass), so a non-scrolling copy
/// is sized through AppKit instead.
@MainActor
enum PanelSizer {
    /// The controller has to live in a window: outside one, `preferredContentSize` comes back too large.
    private static let host: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        return window
    }()

    static func naturalHeight(of view: some View) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        host.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let height = controller.preferredContentSize.height
        host.contentViewController = nil
        return height
    }
}
