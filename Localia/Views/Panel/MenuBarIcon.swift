import AppKit
import SwiftUI

/// The menu-bar icon: the Localia mark, outlined when local mode is off and filled when on; filled with an
/// exclamation badge when the local AI is in trouble, orange while it still answers (fallback) and red when it
/// does not (down).
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.image(state: model.menuBarState))
    }

    static func image(state: MenuBarState) -> NSImage {
        switch state {
        case .off: named("MenuBarOutline", label: String(localized: "Localia, local mode off"))
        case .local: named("MenuBarFilled", label: String(localized: "Localia, local mode on"))
        case .degraded: degradedImage
        case .down: downImage
        }
    }

    private static func named(_ name: String, label: String) -> NSImage {
        let image = NSImage(named: name) ?? NSImage()
        // A template, untinted: the menu bar colours it, and the filled shape carries the state.
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// Built once: `body` runs on every change of the model.
    private static let degradedImage = trouble(badge: .systemOrange, label: String(localized: "Localia, local AI in trouble"))
    private static let downImage = trouble(badge: .systemRed, label: String(localized: "Localia, local AI not answering"))

    /// The filled mark with a coloured badge at the bottom right: a disc with an exclamation mark cut out, set
    /// apart from the mark by a transparent ring. Not a template, so the badge keeps its colour; the mark itself
    /// is drawn in `labelColor`, resolved by the drawing handler for the menu bar's appearance each time it draws,
    /// so it matches the other menu-bar icons in light and dark. Its own image, so the shared named one keeps its
    /// own label. Drawn in the image's own points, at whatever scale the menu bar asks.
    private static func trouble(badge: NSColor, label: String) -> NSImage {
        let filled = NSImage(named: "MenuBarFilled") ?? NSImage()
        let size = filled.size
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return true }
            filled.draw(in: rect)
            // Tint the mark: keep its shape, replace its colour with the menu bar's text colour.
            context.compositingOperation = .sourceAtop
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceAtop)
            context.compositingOperation = .sourceOver
            let d = min(rect.width, rect.height) * 0.46
            let disc = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            let ring = d * 0.14
            // Cuts take an opaque colour: `destinationOut` removes as much as the fill colour's alpha, and
            // `labelColor` is translucent.
            NSColor.black.setFill()
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: disc.insetBy(dx: -ring, dy: -ring)).fill()
            context.compositingOperation = .sourceOver
            badge.setFill()
            NSBezierPath(ovalIn: disc).fill()
            // The "!": a bar and a dot, cut out of the disc.
            NSColor.black.setFill()
            context.compositingOperation = .destinationOut
            let w = d * 0.16
            let bar = NSRect(x: disc.midX - w / 2, y: disc.minY + d * 0.40, width: w, height: d * 0.40)
            NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: disc.midX - w / 2, y: disc.minY + d * 0.17, width: w, height: w)).fill()
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}
