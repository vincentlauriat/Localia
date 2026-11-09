import AppKit
import SwiftUI

/// The menu-bar icon: the Localia mark, outlined when local mode is off and filled when on.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.image(on: model.isLocalModeOn))
    }

    static func image(on: Bool) -> NSImage {
        let label = on ? String(localized: "Localia, local mode on") : String(localized: "Localia, local mode off")
        let image = NSImage(named: on ? "MenuBarFilled" : "MenuBarOutline") ?? NSImage()
        // A template, untinted: the menu bar colours it, and the filled shape carries the state.
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}
