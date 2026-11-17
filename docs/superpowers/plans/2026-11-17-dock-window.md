# Dock Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One main Localia window, with a live diagram of how requests flow (tools → proxy → engines → models) at the top of the Overview, (Dock icon while open) with a short sidebar — Overview · Models · Engines & proxy · Sessions · Usage · Log · Settings — that shows what the Localia proxy recorded and absorbs today's Models and Settings windows.

**Architecture:**
- Aggregation is pure code in `LocaliaCore/Usage/`. It turns `DailyTotal` and `RequestRecord` rows into what the pages show (totals, breakdowns, heatmap, sessions, filters) and is unit-tested with `swift test`.
- The app reads the service's `usage.sqlite` read-only, through a `UsageReading` protocol, so tests inject a fake.
- `UsageModel`, an `ObservableObject`, refreshes while the window is visible.
- The window is one AppKit-hosted `NSWindow` (`WindowManager.Kind.main`) holding a SwiftUI `NavigationSplitView`. It switches the activation policy between `.regular` while open and `.accessory` when closed.

**Tech Stack:** Swift 6, SwiftUI (macOS 14: `NavigationSplitView`, `Table`, Swift Charts not required), XCTest, XcodeGen. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-16-dock-app-proxy-design.md`, sections Goals 1, 4, 5, 6, the Decided items (Dock icon and quit) and the "Proposed by Claude" page list, which this plan adopts. Phase 1 (proxy, `UsageStore`, `ProxyServiceManager`) shipped in 1.3.0.

## Global Constraints

- macOS 14+, `LSUIElement: true` stays in `project.yml`; the Dock icon comes only from switching the activation policy at runtime.
- en + fr for every new string (`Localia/Resources/Localizable.xcstrings`); `DockStringsTests` (Task 3) enforces it for `Localia/Views/Dock/`.
- Simple mode shows Overview, Models and Settings only, and never shows engine names, tok/s, ports or tokens (copy rules of `docs/superpowers/specs/2026-11-13-simple-mode-design.md`).
- The app opens `~/Library/Application Support/Localia/proxy/usage.sqlite` **read-only** (`UsageStore(url:readOnly: true)`); only the service writes.
- Statistics never lie: direct sessions do not appear in usage; unknown token counts are excluded from token totals and from tok/s, never counted as 0.
- Closing the window (⌘W, red button) hides it; Localia stays in the menu bar. ⌘Q quits, warning only when sessions are running.
- The menu-bar panel stays; it gains an "Open Localia" entry.
- Existing tests keep passing; the known hang `SimpleModeAppTests/testSimpleCopyNeverNamesTechnicalThings` (full-suite only) is not this plan's job, but do not add tests to that class.
- Look: `Theme` (teal accent, `CardBackground`), existing card style of the panel.

## Review Focus

1. **No database yet:** a fresh install, a service that never ran, or engines set to Direct. Every page shows an empty state ("No activity yet"), not an error. Tested in Task 2 (`test_missingFile_readsEmpty`) and Task 4 (`test_emptyReader_showsEmptyState`).
2. **Service writing while the app reads:** WAL database, read-only connection. A busy or locked read must not crash or clear the page: keep the last good data and retry on the next tick. Tested in Task 2 (`test_readsWhileWriterInserts`) and Task 4 (`test_failedRefresh_keepsLastData`).
3. **Unknown tokens and unattributed rows:** `TokenUsage.input/output == nil`, `tool == nil`, `folder == nil`, session `"shell"`. They are excluded from token sums and tok/s but counted as requests, and listed under "Unknown tool" / "No folder". Tested in Task 1 (`test_unknownTokens_excludedFromTokensAndSpeed`, `test_nilToolAndFolder_groupedAsUnknown`).
4. **Advanced mode switched off while on an advanced-only page** (Usage, Log…): the window falls back to Overview and never shows a blank detail. Tested in Task 3 (`test_hiddenPage_fallsBackToOverview`).
5. **Day boundaries:** `daily.day` is a local-time `yyyy-MM-dd` string. The period and the heatmap must use the same local calendar, so "today" is not split or dropped. Tested in Task 1 (`test_period_includesToday_localCalendar`).

---

## File Structure

| File | Responsibility |
|---|---|
| `Packages/LocaliaCore/Sources/LocaliaCore/Usage/UsageReport.swift` | `UsagePeriod`, `UsageTotals`, `UsageBreakdownRow`, `HeatmapDay`, `UsageReport.make(...)` |
| `Packages/LocaliaCore/Sources/LocaliaCore/Usage/SessionSummary.swift` | Group `RequestRecord`s into finished sessions |
| `Packages/LocaliaCore/Sources/LocaliaCore/Usage/RequestFilter.swift` | Log filtering |
| `Packages/LocaliaCore/Sources/LocaliaCore/Usage/UsageReader.swift` | `UsageReading` protocol + `UsageStoreReader` (lazy read-only open) |
| `Packages/LocaliaCore/Tests/LocaliaCoreTests/Usage*Tests.swift` | Core tests |
| `Localia/UsageModel.swift` | Refreshing view model over `UsageReading` |
| `Localia/Views/Dock/DockPage.swift` | Page enum, visibility per mode, fallback |
| `Localia/Views/Dock/DockRoot.swift` | `NavigationSplitView` shell |
| `Localia/Views/Dock/OverviewPage.swift`, `EnginesPage.swift`, `SessionsPage.swift`, `UsagePage.swift`, `LogPage.swift` | Pages |
| `Localia/Views/Dock/DockComponents.swift` | `KPITile`, `HeatmapView`, `BreakdownList` |
| `Localia/Views/Dock/FlowGraph.swift`, `FlowDiagramView.swift` | Live diagram of tools → proxy → engines → models (pure graph + view) |
| `Localia/Views/WindowManager.swift` | `.main` kind, `show(page:)`, activation policy |
| `Localia/Views/SettingsView.swift` | Split `ProxySettingsSection` into status/routes (Engines page) and log (Settings) |
| `Localia/Views/Panel/MenuBarPanel.swift`, `SimplePanel.swift` | "Open Localia" entry; folder chooser extracted |
| `Localia/FolderLauncher.swift` | Folder picker + launch shared by panel and Sessions page |
| `Localia/LocaliaApp.swift` | ⌘, command, quit confirmation |
| `LocaliaTests/Dock*Tests.swift` | App tests and snapshots |

---

### Task 1: Usage aggregation in LocaliaCore

**Files:**
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Usage/UsageReport.swift`, `SessionSummary.swift`, `RequestFilter.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/UsageReportTests.swift`, `SessionSummaryTests.swift`, `RequestFilterTests.swift`

**Interfaces:**
- Consumes: `DailyTotal`, `RequestRecord`, `TokenUsage`, `EngineID` (existing, `Proxy/`).
- Produces:
  - `public enum UsagePeriod: String, CaseIterable, Sendable { case day = "1D", week = "7D", month = "30D", quarter = "90D"; public var days: Int; public func start(now: Date, calendar: Calendar) -> Date }`. Here `start` is local midnight `days - 1` days before today, so `.day` is today alone.
  - `public struct UsageTotals: Equatable, Sendable { requests: Int; inputTokens: Int; outputTokens: Int; durationMs: Int; tokensPerSecond: Double? }`
  - `public struct UsageBreakdownRow: Equatable, Sendable, Identifiable { id: String; label: String?; totals: UsageTotals }`. A nil `label` means unknown; the view words it.
  - `public struct HeatmapDay: Equatable, Sendable { day: String; requests: Int; level: Int }`. `level` is 0…4, by quartile of the non-zero days.
  - `public struct UsageReport: Equatable, Sendable { totals; byModel; byTool; byFolder: [UsageBreakdownRow]; heatmap: [HeatmapDay]; busiestDay: HeatmapDay? }` and `public static func make(daily: [DailyTotal], period: UsagePeriod, now: Date, calendar: Calendar) -> UsageReport`. It fills in every day of the period, zeros included, and sorts breakdowns by requests, descending.
  - `public struct SessionSummary: Equatable, Sendable, Identifiable { id: String /* session */; tool: String?; folder: String?; engine: EngineID; models: [String]; start: Date; end: Date; requests: Int; inputTokens: Int?; outputTokens: Int? }` and `public static func group(_ records: [RequestRecord]) -> [SessionSummary]`, newest first. Tokens stay nil when no request of the session reported them.
  - `public struct RequestFilter: Equatable, Sendable { engine: EngineID?; tool: String?; errorsOnly: Bool; text: String }` and `public func apply(_ records: [RequestRecord]) -> [RequestRecord]`. `text` matches model, folder or error, case-insensitively.

**Speed rule:** `tokensPerSecond = outputTokens / (durationMs / 1000)`, computed only over rows whose output tokens are known. It is nil when that duration is 0.

- [ ] **Step 1: Write the failing tests.** Fix the calendar to `Europe/Paris` and `now = 2026-11-17 10:00`:
  - `test_period_includesToday_localCalendar`:
    - `UsagePeriod.week.start` is `2026-11-11 00:00` local;
    - `make(.week)` returns `heatmap.count == 7` and `heatmap.last?.day == "2026-11-17"`.
  - `test_totals_sumRows`: two `DailyTotal`s give the sums.
  - `test_unknownTokens_excludedFromTokensAndSpeed`:
    - input is a `DailyTotal` with 10 output tokens over 1000 ms, plus a `RequestRecord`-derived total whose tokens are unknown. `DailyTotal` stores 0 for unknown, so cover this in `SessionSummaryTests` with `RequestRecord`s whose `usage` is `TokenUsage()`;
    - `SessionSummary.group([...]).first?.outputTokens == nil` when all of its records have nil usage, and `== 10` when one record has 10.
  - `test_nilToolAndFolder_groupedAsUnknown`: in `byTool`, the row with `label == nil` sums the rows whose tool is nil.
  - `test_heatmapLevels_quartiles`: requests `[0, 1, 2, 3, 4]` give levels `[0, 1, 2, 3, 4]`; `busiestDay.requests == 4`.
  - `test_breakdown_sortedByRequestsDesc`.
  - `RequestFilterTests`:
    - `test_errorsOnly` keeps the records with `httpStatus >= 400 || error != nil`;
    - `test_text_matchesModelFolderError_caseInsensitive`;
    - `test_engineAndTool`.
- [ ] **Step 2: Run** `cd Packages/LocaliaCore && swift test --filter "UsageReportTests|SessionSummaryTests|RequestFilterTests"`. Expected: FAIL, the types are not defined.
- [ ] **Step 3: Implement** the three files with the signatures above.
- [ ] **Step 4: Run the same command.** Expected: PASS. Then run `swift test`: the whole package is still green.
- [ ] **Step 5: Commit** `feat(core): add usage report, session summary and request filter`.

### Task 2: Read-only usage reader

**Files:**
- Create: `Packages/LocaliaCore/Sources/LocaliaCore/Usage/UsageReader.swift`
- Test: `Packages/LocaliaCore/Tests/LocaliaCoreTests/UsageReaderTests.swift`

**Interfaces:**
- Consumes: `UsageStore(url:readOnly:)`, `requests(since:limit:)`, `content(for:)`, `dailyTotals(since:)`.
- Produces:
  - `public protocol UsageReading: Sendable { func dailyTotals(since: Date) throws -> [DailyTotal]; func requests(since: Date, limit: Int) throws -> [RequestRecord]; func content(for id: UUID) throws -> RecordedContent? }`
  - `public final class UsageStoreReader: UsageReading, @unchecked Sendable { public init(url: URL); public static func live() -> UsageStoreReader /* Paths.proxy()/usage.sqlite */ }`. It opens the store lazily on the first call. A missing file returns `[]` / nil and retries the open on the next call. Any other open or query error is rethrown.

- [ ] **Step 1: Write the failing tests:**
  - `test_missingFile_readsEmpty`: a temp dir with no file gives `dailyTotals == []`, `requests == []` and no throw.
  - `test_fileCreatedLater_isPickedUp`: read once while the file is missing, then create a writer `UsageStore(readOnly: false)` and insert one record; the next `requests(...)` returns it.
  - `test_readsWhileWriterInserts`: a writer inserts 200 records on a background queue while the reader calls `requests(since:limit:)` 50 times. There is no throw, and the final count is 200.
  - `test_content_roundTrip`.
- [ ] **Step 2: Run** `swift test --filter UsageReaderTests`. Expected: FAIL.
- [ ] **Step 3: Implement `UsageStoreReader`.** Guard the lazy store with a lock, and check `FileManager.default.fileExists` before opening.
- [ ] **Step 4: Run.** Expected: PASS. If `test_readsWhileWriterInserts` throws `SQLITE_BUSY`, set `sqlite3_busy_timeout` on read-only handles in `UsageStore.init` (2000 ms) rather than retrying in the reader.
- [ ] **Step 5: Commit** `feat(core): add read-only usage reader`.

### Task 3: Window shell, pages enum, Dock icon

**Files:**
- Create: `Localia/Views/Dock/DockPage.swift`, `Localia/Views/Dock/DockRoot.swift`
- Modify: `Localia/Views/WindowManager.swift`, `Localia/LocaliaApp.swift`, `Localia/Views/Panel/MenuBarPanel.swift`, `Localia/Views/Panel/SimplePanel.swift`
- Test: `LocaliaTests/DockWindowTests.swift`, `LocaliaTests/DockStringsTests.swift`

**Interfaces:**
- Produces:
  - `enum DockPage: String, CaseIterable, Identifiable { case overview, models, engines, sessions, usage, log, settings; static func visible(advanced: Bool) -> [DockPage]; func resolved(advanced: Bool) -> DockPage; var title: String; var symbol: String }`
    - Simple mode: `[.overview, .models, .settings]`. Advanced mode: every case, in the order above.
    - `resolved` returns `.overview` when the page is hidden in the current mode.
    - Titles: "Overview" / "Aperçu", "Models" / "Modèles", "Engines & proxy" / "Moteurs et proxy", "Sessions" / "Sessions", "Usage" / "Utilisation", "Log" / "Journal", "Settings" / "Réglages".
  - `WindowManager.Kind` gains `.main`. Add `func show(page: DockPage)` and `@Published`-style `var selectedPage: DockPage` on a small `DockNavigation: ObservableObject` owned by `WindowManager`.
  - `show(.models)` and `show(.settings)` now call `show(page: .models)` and `show(page: .settings)`. The separate Models and Settings windows are removed; `ModelsRoot` and `SettingsRoot` become page content.
  - `DockRoot(model:, navigation:)`: a sidebar `List(selection:)` of `DockPage.visible(advanced:)` with a separator before Settings, and a detail switch on the page. Until Tasks 5–9 land, the pages without content show `ContentUnavailableView(page.title, systemImage: page.symbol)`.
- **Activation policy:** `show(.main)` sets `NSApp.setActivationPolicy(.regular)` before ordering the window front. A `NSWindowDelegate.windowWillClose` on the main window sets `.accessory` when no other `.main` is visible. The main window's default size is 960×640 and its minimum is 760×520. Save the frame with `setFrameAutosaveName("LocaliaMain")`.
- **Menu commands:** `LocaliaApp` adds `.commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { windows.show(page: .settings) }.keyboardShortcut(",") } }`.
- **Panels:** `MenuBarPanel` and `SimplePanel` get an "Open Localia" row, the first item of the footer, calling `windows.show(page: .overview)`. Their existing "Models…" and "Settings…" buttons call `show(page:)`. DEBUG `-LocaliaOpen` accepts the `DockPage` raw values.

- [ ] **Step 1: Write the failing tests** in `DockWindowTests`, using the `makeModel` pattern of `PanelSnapshotTests`:
  - `test_visiblePages_simpleAndAdvanced`;
  - `test_hiddenPage_fallsBackToOverview`: `DockPage.usage.resolved(advanced: false) == .overview`;
  - `test_modeSwitch_onAdvancedPage_selectsOverview`: navigation on `.log`, then `settings.advancedMode = false`, then `navigation.selectedPage == .overview` after the main queue drains;
  - `test_showMain_setsRegular_closeSetsAccessory`: `NSApp.activationPolicy()` is `.regular` after `show(page:)` and `.accessory` after `window(.main)?.close()`;
  - `test_showSettingsKind_opensMainOnSettings`.
- [ ] **Step 2: Write `DockStringsTests.test_everyDockStringHasAFrenchTranslation`.** Same approach as `ProxyStringsTests`, but it scans every `.swift` under `Localia/Views/Dock/` and asserts that each key has a French value. It does not assert a count.
- [ ] **Step 3: Run** `xcodegen generate && xcodebuild -project Localia.xcodeproj -scheme Localia test -only-testing:LocaliaTests/DockWindowTests -only-testing:LocaliaTests/DockStringsTests`. Expected: FAIL.
- [ ] **Step 4: Implement** the shell, the `WindowManager` changes, the commands and the panel entries. Add the fr strings.
- [ ] **Step 5: Run** the same tests, then the existing `PanelSnapshotTests`, `ModelsSnapshotTests` and `AppModelTests`. Expected: PASS. Update window-size assertions that targeted the old Models and Settings windows so they assert the page instead.
- [ ] **Step 6: Commit** `feat: add the main Localia window with its sidebar`.

### Task 4: UsageModel

**Files:**
- Create: `Localia/UsageModel.swift`
- Modify: `Localia/Services.swift` (`AppDependencies.usage: any UsageReading`, live = `UsageStoreReader.live()`), `Localia/Views/WindowManager.swift` (owns the `UsageModel`)
- Test: `LocaliaTests/UsageModelTests.swift`

**Interfaces:**
- Consumes: `UsageReading`, `UsageReport`, `SessionSummary`, `RequestFilter` (Tasks 1–2).
- Produces:
  - `@MainActor final class UsageModel: ObservableObject`
  - published state:
    - `period: UsagePeriod = .week`
    - `report: UsageReport?`
    - `overview: UsageReport?` (always `.week`, for the Overview tiles)
    - `heatmap12Weeks: [HeatmapDay]`
    - `requests: [RequestRecord]`
    - `sessions: [SessionSummary]`
    - `filter = RequestFilter(...)`
    - `lastError: String?`
    - `isEmpty: Bool`
  - `func refresh(now: Date = Date()) async`:
    - runs the store reads off the main actor;
    - reads `dailyTotals` since 84 days ago for `heatmap12Weeks` and the `.quarter` period, and `requests` from the last 90 days, limit 2000;
    - keeps the previous data when a read throws, and sets `lastError`.
  - `func startAutoRefresh(every: Duration = .seconds(5))` and `stopAutoRefresh()`, called by `WindowManager` on main-window show and close.
  - `var filteredRequests: [RequestRecord]` applies `filter`.
- `isEmpty` is true when the report has 0 requests in the 90 days, the request list is empty and there is no error.

- [ ] **Step 1: Write the failing tests**, with a `FakeUsageReader` whose rows and error can be set:
  - `test_emptyReader_showsEmptyState`
  - `test_refresh_buildsReportForPeriod`
  - `test_failedRefresh_keepsLastData`: rows, refresh, then set an error and refresh again; `report` is unchanged and `lastError != nil`
  - `test_periodChange_rebuildsWithoutRereading`: switching the period recomputes from the cached daily rows, and the fake's read count does not increase
- [ ] **Step 2: Run** the `xcodebuild … -only-testing:LocaliaTests/UsageModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Cache the last 90 days of daily rows.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: add the usage model read from the proxy store`.

### Task 5: Models, Settings and Engines & proxy pages

**Files:**
- Create: `Localia/Views/Dock/EnginesPage.swift`
- Modify: `Localia/Views/SettingsView.swift`, `Localia/Views/Dock/DockRoot.swift`
- Test: `LocaliaTests/DockSnapshotTests.swift` (new; same output rules as `PanelSnapshotTests`, `$LOCALIA_SNAPSHOT_DIR`)

**Interfaces:**
- Split `ProxySettingsSection` into:
  - `ProxyStatusSection(model:)`: status line, the unavailable reason, Restart, and "Open Login Items";
  - `ProxyRoutesSection(model:)`: the per-engine Direct / Via Localia pickers;
  - `ProxyLogSection(model:)`: "Record request content", the retention slider over `ProxyConfig.retentionRange`, and Erase….
- `SettingsView` (the Advanced tab) keeps `ProxyLogSection` and loses the "Engines" section, the status section and the routes section. They move to `EnginesPage`.
- `EnginesPage(model:)` is a `Form(.grouped)` with three blocks: today's "Engines" section content (moved as is), then `ProxyStatusSection`, then `ProxyRoutesSection`.
- Models page: `ModelsRoot(model:)` unchanged. Settings page: `SettingsRoot(model:)` unchanged.

- [ ] **Step 1: Write the failing snapshot tests:**
  - `test_enginesPage_light_dark`
  - `test_settingsPage_advanced_hasLogSectionNotRoutes`: it walks the rendered view's accessibility labels, or asserts on `SettingsView`'s section list helper. If neither is feasible, assert through a `static let sections: [String]` that `SettingsView` exposes for tests.
  - `test_modelsPage_simple_and_advanced`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the split and the page. Keep every string key that moves unchanged, so the translations carry over.
- [ ] **Step 4: Run.** Expected: PASS, and `ProxyStringsTests` still passes. Look at the PNGs in the snapshot dir, light and dark.
- [ ] **Step 5: Commit** `feat: move engines and proxy controls into their own page`.

### Task 6: Overview page

**Files:**
- Create: `Localia/Views/Dock/OverviewPage.swift`, `Localia/Views/Dock/DockComponents.swift`
- Test: `LocaliaTests/DockSnapshotTests.swift`, `LocaliaTests/DockCopyTests.swift`

**Interfaces:**
- Consumes: `UsageModel.overview`, `heatmap12Weeks`, `AppModel.runningSessions`, `AppModel.proxyState`, `settings.engineRoutes`.
- Produces:
  - `KPITile(title: String, value: String, caption: String?)`
  - `HeatmapView(days: [HeatmapDay])`: columns are weeks and rows are weekdays, the first weekday comes from `Calendar.current`, and the cell color is `Theme.accent` at an opacity per level. Each cell has an accessibility label "\(date): \(n) requests" (fr: "\(date) : \(n) requêtes").
  - `BreakdownList(rows: [UsageBreakdownRow], unknownLabel: String)`
- **Advanced mode:**
  - four tiles: "Tokens (7 days)" (input + output), "Requests (7 days)", "Average speed" (`Fmt.tps`, "—" when nil) and "Active sessions" (`runningSessions.count`);
  - the 12-week heatmap;
  - the engines list: each engine with its install state and a Direct / Via Localia picker. MLX is shown as always via Localia, with no picker.
- **Simple mode:**
  - "Used \(n) times this week" (fr: "Utilisée \(n) fois cette semaine"); with n == 0, "Not used yet this week" (fr: "Pas encore utilisée cette semaine");
  - speed as `SpeedBucket(tokensPerSecond:).title`, hidden when nil;
  - the heatmap without numbers in its labels. It shows "Used on \(date)" or "Not used on \(date)".
  - no tokens, no engines, no ports.
- **Empty state** (`usage.isEmpty`): one line, "No activity yet. Usage appears here after your first session through Localia." (fr: "Aucune activité pour l'instant. L'utilisation s'affiche ici après votre première session via Localia."). The engines list stays.
- When the proxy is unavailable, show the existing "Usage statistics are paused" banner above the tiles, reusing the key.

- [ ] **Step 1: Write the failing tests:**
  - `DockCopyTests.test_simpleOverview_namesNoTechnicalThings`: render `OverviewPage` in simple mode with a fake report, collect its text through `NSHostingView` accessibility, or build the strings from `OverviewPage.simpleLines(report:)`, a pure static helper. Assert that no line contains "token", "tok/s", "Ollama", "llama", "MLX", "11438" or "proxy", case-insensitively.
  - Snapshots `test_overview_advanced`, `test_overview_simple` and `test_overview_empty`, in light and dark.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Add the fr strings.
- [ ] **Step 4: Run.** Expected: PASS, and look at the PNGs.
- [ ] **Step 5: Commit** `feat: add the Overview page`.

### Task 7: Flow diagram ("How it works") on the Overview

Added at Vincent's request (2026-11-17): a live diagram of the parts and the flows. It sits at the top of the Overview, in both modes.

**Files:**
- Create: `Localia/Views/Dock/FlowGraph.swift` (pure model), `Localia/Views/Dock/FlowDiagramView.swift`
- Modify: `Localia/Views/Dock/OverviewPage.swift` (diagram card first)
- Test: `LocaliaTests/FlowGraphTests.swift`, `LocaliaTests/DockSnapshotTests.swift`

**Interfaces:**
- Consumes:
  - `AppModel`: `localTools`, `engineStates`, `loaded`, `runningSessions`, `proxyState`, `proxyFallbackActive`, `controller` (local mode on/off);
  - `settings.engineRoutes`;
  - `UsageModel.requests`, for recent traffic.
- Produces:
  - `struct FlowNode: Identifiable, Equatable { enum Kind { case tool, terminal, proxy, engine, model, cloud, simpleClaude, simpleLocalia, simpleLocalAI }; let id: String; let kind: Kind; let label: String; let detail: String?; let state: NodeState /* ok, idle, warning, off */; let page: DockPage? }`
  - `struct FlowEdge: Identifiable, Equatable { let id: String; let from: String; let to: String; let route: Route /* proxied, direct, cloud */; let active: Bool /* a running session uses it */; let recent: Bool /* a request in the last 5 minutes */ }`
  - `struct FlowGraph: Equatable { nodes: [FlowNode]; edges: [FlowEdge]; columns: [[String]] /* node ids per column, left to right */ }`
  - `static func make(_ input: FlowInput, advanced: Bool, now: Date) -> FlowGraph`, where `FlowInput` is a plain struct copied from the published values above, so the tests need no `AppModel`.
- **Advanced graph:**
  - Four columns: tools (Claude Code, plus the installed Codex, OpenCode and Pi, plus "Terminal" when the every-`claude` scope is on), then "Localia proxy :11438", then the installed engines (name and port), then the loaded models.
  - Routing:
    - an engine routed Via Localia gets the edges tool → proxy → engine;
    - an engine routed Direct gets tool → engine edges drawn dashed, labelled "Direct — not counted" (fr: « Direct — non comptabilisé »);
    - MLX always goes via the proxy;
    - when `proxyFallbackActive` is set, proxied routes are drawn as direct and the proxy node is `.warning`, labelled "Paused" (fr: « En pause »).
  - "Anthropic cloud" is a node in the engines column, reached from Claude Code when local mode is off.
- **Simple graph:** three nodes, "Claude" → "Localia" → "AI on this Mac" (fr: « Claude » → « Localia » → « IA de ce Mac »). When local mode is off, Claude → "Anthropic cloud" (fr: « Cloud d'Anthropic ») is the active edge instead. No engine, port, model id or token appears.
- **View:**
  - Draw with a SwiftUI `Canvas` (edges as Bézier curves between the columns' anchor points) under the node cards, which are regular views laid out in an `HStack` of `VStack`s.
  - Node colors: proxy `Theme.accent`, engines `Theme.blue`, cloud `Theme.slate`, warning `Theme.orange`, off at 40 % opacity.
  - An active edge carries moving dots (`TimelineView(.animation)`). A recent edge is drawn thicker. With Reduce Motion on, there are no moving dots: active edges are solid and thick.
  - Clicking a node navigates to its `page`: proxy and engines go to `.engines`, tools to `.sessions`, models to `.models`. Simple nodes have no page.
  - Every node has an accessibility label, for example "Ollama, port 11434, via Localia, 1 session running".

- [ ] **Step 1: Write the failing tests** in `FlowGraphTests`:
  - `test_proxiedEngine_edgesGoThroughProxy`: Ollama via Localia gives the edges `claude→proxy` and `proxy→ollama`, and no `claude→ollama`.
  - `test_directEngine_edgeBypassesProxy`: the route of the `claude→llamacpp` edge is `.direct`.
  - `test_mlx_alwaysThroughProxy_evenIfRouteDirect`.
  - `test_fallbackActive_proxyWarning_andDirectEdges`.
  - `test_runningSession_marksItsEdgesActive`: a running Ollama session from Claude Code makes both proxied edges `active`.
  - `test_recentRequest_marksEdgeRecent_onlyWithin5Minutes`: requests 4 and 6 minutes old.
  - `test_localModeOff_cloudEdgeActive`.
  - `test_simpleGraph_hasNoTechnicalLabels`: no node label or detail contains "Ollama", "llama", "MLX", "proxy", "11438" or "token".
  - `test_uninstalledTools_andEngines_absent`.
- [ ] **Step 2: Write the snapshots** `test_flow_advanced_proxiedAndDirect`, `test_flow_fallback`, `test_flow_simple_localOn` and `test_flow_simple_localOff`, in light and dark.
- [ ] **Step 3: Run** `xcodebuild … -only-testing:LocaliaTests/FlowGraphTests -only-testing:LocaliaTests/DockSnapshotTests`. Expected: FAIL.
- [ ] **Step 4: Implement** `FlowGraph.make`, then the view, then place it as the first card of `OverviewPage`. Add the fr strings.
- [ ] **Step 5: Run.** Expected: PASS. Look at the PNGs: edges do not cross the node cards, and labels are readable in fr.
- [ ] **Step 6: Commit** `feat: add the live flow diagram to the Overview`.

### Task 8: Usage page

**Files:**
- Create: `Localia/Views/Dock/UsagePage.swift`
- Test: `LocaliaTests/DockSnapshotTests.swift`

**Interfaces:**
- Consumes: `UsageModel.period` (a segmented picker over `UsagePeriod.allCases`, labels "1D 7D 30D 90D" in both languages), `report`, `HeatmapView`, `BreakdownList`.
- Layout, top to bottom:
  - the totals row: requests, input tokens, output tokens, average speed, total time (formatted with `Duration.UnitsFormatStyle`);
  - the heatmap of the period;
  - "Busiest day: \(date), \(n) requests" (fr: "Jour le plus actif : \(date), \(n) requêtes"), hidden when nil;
  - three `BreakdownList`s: "By model", "By tool" and "By folder" (fr: "Par modèle", "Par outil", "Par dossier"). The unknown labels are "Unknown model", "Unknown tool" and "No folder" (fr: "Modèle inconnu", "Outil inconnu", "Sans dossier"). Folders show the last path component, with the full path in `help`.

- [ ] **Step 1: Write the failing snapshots** `test_usage_week` and `test_usage_quarter_withUnknowns`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS, and look at the PNGs.
- [ ] **Step 5: Commit** `feat: add the Usage page`.

### Task 9: Sessions page

**Files:**
- Create: `Localia/Views/Dock/SessionsPage.swift`, `Localia/FolderLauncher.swift`
- Modify: `Localia/Views/Panel/MenuBarPanel.swift` (uses `FolderLauncher`)
- Test: `LocaliaTests/DockSnapshotTests.swift`, `LocaliaTests/FolderLauncherTests.swift`

**Interfaces:**
- `@MainActor enum FolderLauncher { static func choose(tool: LocalToolRow?, model: AppModel, pick: () -> URL? = FolderLauncher.openPanel) async }`. It is extracted from `MenuBarPanel.chooseFolder` / `launch`: same prompt strings, then `AppAlert` presentation through `AlertPresenter.present(model)`. The panel keeps its `dismiss()` before calling it.
- `SessionsPage(model:, usage:)`:
  - **Running**, from `model.runningSessions`: tool, model, engine, folder, and an "End" button where the panel has one today.
  - **Finished**, from `usage.sessions`, with the running ids excluded: a `Table` with the columns Tool, Folder, Model(s), Engine, Started, Duration and Tokens. Tokens are in + out, or "—" when nil. Session `"shell"` rows read "Started from a terminal" (fr: "Lancée depuis un terminal").
  - A "New session…" button in the toolbar calls `FolderLauncher.choose(tool: nil, model:)`. A menu next to it lists the other tools of `model.localTools`.
  - Footnote: "Sessions run direct are not listed." (fr: "Les sessions en direct ne sont pas listées.").

- [ ] **Step 1: Write the failing tests:**
  - `FolderLauncherTests.test_cancelledPick_launchesNothing`: `pick` returns nil, and the fake tool records no launch;
  - `test_pickedFolder_launches`;
  - the snapshot `test_sessions_runningAndFinished`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Switch `MenuBarPanel` to `FolderLauncher` and check that `PanelSnapshotTests` is unchanged.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: add the Sessions page`.

### Task 10: Log page

**Files:**
- Create: `Localia/Views/Dock/LogPage.swift`
- Test: `LocaliaTests/DockSnapshotTests.swift`, `LocaliaTests/UsageModelTests.swift`

**Interfaces:**
- Consumes: `UsageModel.filteredRequests`, `filter`, and `UsageReading.content(for:)` through a new `UsageModel.content(for id: UUID) async -> RecordedContent?`.
- Layout:
  - a filter bar: an engine picker (All + engines), a tool picker (All + the tools present), an "Errors only" toggle, and a search field;
  - a `Table` with the columns Time, Tool, Model, Engine, Status, In, Out, Duration and tok/s;
  - selecting a row opens a detail pane on the right with the metadata and then the content:
    - when the content is recorded, the request and the response as pretty-printed JSON when they parse, else UTF-8 text, in a monospaced scrollable `Text`, plus "Truncated" when `truncated`;
    - otherwise, "Content not recorded. Turn on Record request content in Settings to keep it." (fr: "Contenu non enregistré. Activez « Enregistrer le contenu des requêtes » dans les Réglages pour le conserver.").
- The footer reads "Showing the last \(n) requests" (fr: "\(n) dernières requêtes affichées"); the limit is 2000.

- [ ] **Step 1: Write the failing tests:**
  - `UsageModelTests.test_content_forUnknownId_isNil`
  - `test_filteredRequests_followFilter`
  - snapshots `test_log_withDetail_recorded` and `test_log_withDetail_notRecorded`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: add the Log page`.

### Task 11: Quit confirmation, docs and live check

**Files:**
- Modify: `Localia/LocaliaApp.swift`, `README.md`
- Test: `LocaliaTests/DockWindowTests.swift`

**Interfaces:**
- `static func quitWarning(running: [RunningSession]) -> (message: String, info: String)?`. It returns nil when `running` is empty, and the alert is shown only when it is non-nil.
  - Message: "Quit Localia?" (fr: « Quitter Localia ? »).
  - Info: "\(n) sessions are running. Sessions through Localia keep running; MLX sessions stop." The MLX clause appears only when one of them uses MLX. fr: « \(n) sessions sont en cours. Les sessions via Localia continuent ; les sessions MLX s'arrêtent. »
  - Buttons: "Quit" / "Cancel" (fr: « Quitter » / « Annuler »). Cancel returns `.terminateCancel`.
- README:
  - update the Features table: the main window and its pages, Dock icon only while open;
  - the project layout gains `Views/Dock/`;
  - roadmap: check the Dock window.

- [ ] **Step 1: Write the failing tests:**
  - `test_quitWarning_nilWhenNoSessions`
  - `test_quitWarning_mentionsMLXOnlyWhenPresent`
- [ ] **Step 2: Run.** Expected: FAIL. **Step 3: Implement.** **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Full suites.**
  - `cd Packages/LocaliaCore && swift test` must pass.
  - `xcodebuild … test -skip-testing:LocaliaTests/SimpleModeAppTests/testSimpleCopyNeverNamesTechnicalThings` must pass, and that test must pass when run alone.
- [ ] **Step 6: Live check on a Debug build.**
  - Open the window from the panel. The Dock icon appears, and ⌘W makes it disappear.
  - ⌘, opens Settings.
  - Run one local session through the proxy. It appears in Overview, Usage, Sessions and Log within 5 s.
  - Switching advanced mode off while on Log falls back to Overview.
  - ⌘Q with a running session shows the warning.
  - Take screenshots in light and dark and look at them.
- [ ] **Step 7: Commit** `feat: confirm quit with running sessions; docs for the main window`.
