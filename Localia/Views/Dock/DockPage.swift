import Foundation

/// The pages of the main window. Simple mode shows three; advanced mode shows all of them.
enum DockPage: String, CaseIterable, Identifiable {
    case overview, models, engines, sessions, usage, log, settings

    var id: String { rawValue }

    static func visible(advanced: Bool) -> [DockPage] {
        advanced ? allCases : [.overview, .models, .settings]
    }

    /// `self` when it is shown in this mode, else the overview.
    func resolved(advanced: Bool) -> DockPage {
        Self.visible(advanced: advanced).contains(self) ? self : .overview
    }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .models: String(localized: "Models")
        case .engines: String(localized: "Engines & proxy")
        case .sessions: String(localized: "Sessions")
        case .usage: String(localized: "Usage")
        case .log: String(localized: "Log")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .models: "cube"
        case .engines: "server.rack"
        case .sessions: "terminal"
        case .usage: "chart.bar"
        case .log: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}
