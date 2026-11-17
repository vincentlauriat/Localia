import SwiftUI

/// What the main window hosts: a sidebar of pages and the selected page.
struct DockRoot: View {
    static let sidebarMaxWidth: CGFloat = 240

    @ObservedObject var model: AppModel
    @ObservedObject var navigation: DockNavigation
    @ObservedObject var usage: UsageModel

    private var advanced: Bool { model.settings.advancedMode }
    private var page: DockPage { navigation.selectedPage.resolved(advanced: advanced) }

    private var selection: Binding<DockPage?> {
        Binding(get: { page }, set: { if let p = $0 { navigation.selectedPage = p } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(DockPage.visible(advanced: advanced).filter { $0 != .settings }) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
                Divider()
                Label(DockPage.settings.title, systemImage: DockPage.settings.symbol).tag(DockPage.settings)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: Self.sidebarMaxWidth)
        } detail: {
            detail
        }
        // The window's only alert: no page presents one, so engine results and errors show wherever they happen.
        .alert(item: model.simpleAlertBinding) { Self.alert($0, model: model) }
    }

    /// How an alert reads in the current mode: plain words in simple mode.
    static func alert(_ alert: AppAlert, model: AppModel) -> Alert {
        model.isSimpleMode ? alert.simplified(heavyApps: model.heavyApps).swiftUIAlert : alert.swiftUIAlert
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .overview: OverviewPage(model: model, usage: usage, navigation: navigation)
        case .models: ModelsRoot(model: model)
        case .engines: EnginesPage(model: model)
        case .sessions: SessionsPage(model: model, usage: usage)
        case .usage: UsagePage(usage: usage, modelName: model.friendlyName(for:))
        case .log: LogPage(usage: usage, modelName: model.friendlyName(for:))
        case .settings: SettingsRoot(model: model)
        }
    }
}
