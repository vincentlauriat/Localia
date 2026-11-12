import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater. Sparkle refuses to verify updates without an EdDSA public key, so a build whose
/// `SUPublicEDKey` is empty (a dev build, or a release before the key exists) never starts the updater:
/// no automatic checks, no error dialogs, and the menu item is disabled.
@MainActor
final class Updater: ObservableObject {
    let controller: SPUStandardUpdaterController?
    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO): false while a check or an update session is running.
    @Published private(set) var canCheckForUpdates = false
    private var observation: AnyCancellable?

    /// True when `info` carries a non-empty `SUPublicEDKey`.
    nonisolated static func hasPublicKey(_ info: [String: Any]?) -> Bool {
        guard let key = info?["SUPublicEDKey"] as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(info: [String: Any]? = Bundle.main.infoDictionary, enabled: Bool = true) {
        if enabled, Self.hasPublicKey(info) {
            let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            controller = c
            observation = c.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    /// The menu item is enabled only when the updater exists and is idle.
    var canCheckNow: Bool { Self.canCheckNow(isAvailable: isAvailable, canCheckForUpdates: canCheckForUpdates) }

    nonisolated static func canCheckNow(isAvailable: Bool, canCheckForUpdates: Bool) -> Bool {
        isAvailable && canCheckForUpdates
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
