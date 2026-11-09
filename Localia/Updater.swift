import Foundation
import Sparkle

/// Owns the Sparkle updater. Sparkle refuses to verify updates without an EdDSA public key, so a build whose
/// `SUPublicEDKey` is empty (a dev build, or a release before the key exists) never starts the updater:
/// no automatic checks, no error dialogs, and the menu item is disabled.
@MainActor
final class Updater {
    let controller: SPUStandardUpdaterController?

    /// True when `info` carries a non-empty `SUPublicEDKey`.
    nonisolated static func hasPublicKey(_ info: [String: Any]?) -> Bool {
        guard let key = info?["SUPublicEDKey"] as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(info: [String: Any]? = Bundle.main.infoDictionary, enabled: Bool = true) {
        if enabled, Self.hasPublicKey(info) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
