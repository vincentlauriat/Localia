import AppKit
import SwiftUI

/// The menu-bar icon: the Localia mark, outlined when local mode is off and filled when on; filled with an
/// exclamation badge when the local AI is in trouble.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.image(state: model.menuBarState))
    }

    static func image(state: MenuBarState) -> NSImage {
        switch state {
        case .off: named("MenuBarOutline", label: String(localized: "Localia, local mode off"))
        case .local: named("MenuBarFilled", label: String(localized: "Localia, local mode on"))
        case .trouble: trouble()
        }
    }

    private static func named(_ name: String, label: String) -> NSImage {
        let image = NSImage(named: name) ?? NSImage()
        // A template, untinted: the menu bar colours it, and the filled shape carries the state.
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// The filled mark with a badge at the bottom right: a disc with an exclamation mark cut out, set apart from
    /// the mark by a transparent ring. A new image each time, so the shared named one keeps its own label. Drawn
    /// in the image's own points, at whatever scale the menu bar asks.
    private static func trouble() -> NSImage {
        let filled = NSImage(named: "MenuBarFilled") ?? NSImage()
        let size = filled.size
        let image = NSImage(size: size, flipped: false) { rect in
            filled.draw(in: rect)
            guard let context = NSGraphicsContext.current else { return true }
            let d = min(rect.width, rect.height) * 0.46
            let disc = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            let ring = d * 0.14
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: disc.insetBy(dx: -ring, dy: -ring)).fill()
            context.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: disc).fill()
            // The "!": a bar and a dot, cut out of the disc.
            context.compositingOperation = .destinationOut
            let w = d * 0.16
            let bar = NSRect(x: disc.midX - w / 2, y: disc.minY + d * 0.40, width: w, height: d * 0.40)
            NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: disc.midX - w / 2, y: disc.minY + d * 0.17, width: w, height: w)).fill()
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Localia, local AI in trouble")
        return image
    }
}
