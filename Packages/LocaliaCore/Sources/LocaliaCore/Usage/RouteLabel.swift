import Foundation

/// How the Log names the route the router took for a request (`reason` of `RequestRecord`, written by
/// `LocaliaRouter/src/router/mod.rs`). The normal route says nothing; a value this build does not know shows
/// nothing rather than a raw identifier. The strings live in the app's catalog (`Bundle.main`).
public enum RouteLabel {
    /// `routedTo` is not used yet: the Log's Engine column already shows the engine used (the router writes
    /// `routed_to` equal to the row's engine). Kept for a label that would name it.
    public static func text(routedTo: String?, reason: String?) -> String? {
        switch reason {
        case "engine-down": String(localized: "Fallback — engine stopped")
        case "pinned": String(localized: "Fixed engine")
        default: nil
        }
    }
}
