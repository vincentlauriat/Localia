import AppKit

/// Asks which folder a coding tool works in, launches it there and presents any error. Shared by the menu
/// bar panel and the main window; `tool` nil is Claude Code.
@MainActor
enum FolderLauncher {
    static func choose(tool: LocalToolRow?, model: AppModel,
                       pick: @MainActor (LocalToolRow?) -> URL? = FolderLauncher.openPanel) async {
        NSApp.activate(ignoringOtherApps: true)
        guard let folder = pick(tool) else { return }
        await model.launch(folder: folder, toolID: tool?.id)
        AlertPresenter.present(model)
    }

    static func openPanel(tool: LocalToolRow?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Launch")
        panel.message = tool.map { String(localized: "Choose the folder \($0.displayName) works in.") }
            ?? String(localized: "Choose the folder Claude Code works in.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
