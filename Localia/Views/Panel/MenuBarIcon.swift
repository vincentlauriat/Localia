import AppKit
import SwiftUI

/// The menu-bar icon: `cpu` when local mode is off, an accent-tinted `cpu.fill` when on.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.image(on: model.isLocalModeOn))
    }

    static func image(on: Bool) -> NSImage {
        let name = on ? "cpu.fill" : "cpu"
        let label = on ? String(localized: "Localia, local mode on") : String(localized: "Localia, local mode off")
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: label) else { return NSImage() }
        if on, let tinted = image.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) {
            image = tinted
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        return image
    }
}
