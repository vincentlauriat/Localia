import AppKit
import SwiftUI

/// Design tokens of the menu-bar panel, ported from ClaudeCockpit's `Theme` and trimmed to what the panel uses.
/// Colours are adaptive through `NSColor(name:)`, so they follow the window's appearance, not just SwiftUI's.
enum Theme {
    // MARK: Layout
    static let panelWidth: CGFloat = 340
    static let cardRadius: CGFloat = 14

    // MARK: Colours
    /// Green: speed, memory bar, loaded and running dots.
    static let local = adaptive(light: 0x22A34A, dark: 0x34C759)
    /// Local-mode accent: the logo teal, lightened in dark mode to stay legible. Used for the badge text, the
    /// airplane, the switch and the speed while local mode is on. Contrast on the card: 6.0:1 light, 7.5:1 dark.
    static let accent = adaptive(light: 0x045A54, dark: 0x4FD1C5)
    /// The badge fill: the accent at 12 % (light) or 18 % (dark), so its text keeps at least 4.5:1.
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(hex: 0x4FD1C5).withAlphaComponent(0.18)
            : NSColor(hex: 0x045A54).withAlphaComponent(0.12)
    })
    static let blue = adaptive(light: 0x2A78D6, dark: 0x4D8CE0)
    static let orange = adaptive(light: 0xD9822B, dark: 0xF0A04B)
    static let red = adaptive(light: 0xD93F3F, dark: 0xFF6961)
    static let slate = adaptive(light: 0x5B6470, dark: 0x9AA3AE)

    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.07)
    static let track = Color.primary.opacity(0.12)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Containers

struct CardBackground: ViewModifier {
    var fill: Color = Theme.cardFill
    var stroke: Color = Theme.cardStroke

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(stroke, lineWidth: 0.5))
    }
}

extension View {
    func card(fill: Color = Theme.cardFill, stroke: Color = Theme.cardStroke) -> some View {
        modifier(CardBackground(fill: fill, stroke: stroke))
    }
}
