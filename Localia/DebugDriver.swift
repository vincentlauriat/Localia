#if DEBUG
import Foundation
import LocaliaCore

/// DEBUG-only E2E driver: `localia://debug/<action>?...` calls the same AppModel methods the menu and
/// window buttons call, so the flows can be exercised and checked without clicks. Not in Release builds.
@MainActor
enum DebugDriver {
    static func handle(_ url: URL, model: AppModel, windows: WindowManager) -> Bool {
        guard url.scheme == "localia", url.host == "debug" else { return false }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        Task {
            switch url.path {
            case "/open":
                if let t = q["tab"].flatMap(Int.init) { model.modelsTab = t }
                if let k = WindowManager.Kind(rawValue: q["window"] ?? "") { windows.show(k) }
            case "/default":
                if let row = model.installed.first(where: { $0.name == q["name"] }) { await model.setDefault(row) }
            case "/localmode": await model.setLocalMode(q["on"] == "1")
            case "/launch": await model.launch(folder: URL(fileURLWithPath: q["path"] ?? NSHomeDirectory()))
            case "/download":
                let all = (model.recommendation?.candidates ?? []) + (model.recommendation?.uncertain ?? [])
                if let c = all.first(where: { $0.id == q["id"] }) { model.download(c) }
            case "/measure":
                if let row = model.installed.first(where: { $0.name == q["name"] }) { await model.measureSpeed(row) }
            case "/delete":
                if let row = model.installed.first(where: { $0.name == q["name"] }) { await model.delete(row) }
            case "/chat": await model.chat()
            case "/free": await model.freeMemory()
            case "/terminal": if let t = TerminalApp(rawValue: q["app"] ?? "") { model.settings.terminalApp = t }
            case "/refresh": await model.refreshAll(); await model.refreshRecommendations()
            default: break
            }
            dump(model)
        }
        return true
    }

    /// Writes the visible state to `AppSupport/logs/debug-state.json`.
    static func dump(_ model: AppModel) {
        func row(_ c: ModelCandidate) -> [String: Any] {
            ["id": c.id, "fit": c.fit.rawValue, "slow": c.slow, "tps": c.estimatedTPS, "memoryGB": c.memoryGB,
             "speedMeasured": c.speedIsMeasured, "memoryMeasured": c.memoryIsMeasured]
        }
        let state: [String: Any] = [
            "statusLine": model.statusLine,
            "busy": model.busyMessage ?? "",
            "alert": model.alert.map { "\($0.title): \($0.message)" } ?? "",
            "localMode": model.isLocalModeOn,
            "candidates": (model.recommendation?.candidates ?? []).map(row),
            "uncertain": (model.recommendation?.uncertain ?? []).map(row),
            "emptyReason": model.recommendation?.emptyReason.map { "\($0)" } ?? "",
            "installed": model.installed.map { ["engine": $0.engine.rawValue, "name": $0.name, "loaded": $0.loaded,
                                                "deletable": $0.deletable, "default": $0.isDefault] },
            "downloads": model.downloads.values.map { ["id": $0.candidateID, "done": $0.done, "total": $0.total ?? -1] },
            "modelIDs": model.settings.modelIDs,
            "measuredTPS": model.settings.measurements.tps,
            "measuredMemoryGB": model.settings.measurements.memoryGB,
        ]
        let url = Paths.logs().appendingPathComponent("debug-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
