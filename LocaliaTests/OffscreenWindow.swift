import AppKit

extension NSWindow {
    /// Puts a snapshot window on screen far outside every display, without the order-in/out animation.
    /// Off every display that animation never gets a display tick, so it never ends: each one parks a
    /// dispatch thread for good (`-[NSAnimation _runBlocking]`), and after 64 of them the test host runs out
    /// of threads and hangs. With `animationBehavior = .none` neither `orderFront` nor `close` animates.
    func orderFrontOffscreen() {
        animationBehavior = .none
        setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        orderFront(nil)
    }
}
