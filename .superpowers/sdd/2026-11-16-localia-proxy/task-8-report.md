# Task 8 report: App-side service manager and routing

Status: DONE. Commit `9b0bbae feat: route engines through the Localia proxy` (no Co-Authored-By trailer).

## What was implemented

- **SettingsStore**: `engineRoutes: [EngineID: EngineRoute]` (default `[.ollama: .proxy, .llamaCpp: .proxy]`, persisted as `[rawValue: rawValue]` under `engineRoutes`), `logContent: Bool` (false), `logRetentionDays: Int` (7, clamped to `ProxyConfig.retentionRange` 1...90 in `didSet` and at load; a missing key gives 7, not 0→1). Added a computed `proxyConfig`.
- **ProxyConfig**: `init()` became `init(logContent: Bool = false, retentionDays: Int = 7)`, which clamps in the init because `didSet` doesn't run there. Existing `ProxyConfig()` call sites are unchanged.
- **LocalModeController**: new `routes: @escaping @Sendable () -> RouteResolver` init parameter. Its default is `RouteResolver(routes: [:], proxyHealthy: false)`, so the controller goes direct and existing callers and tests are unchanged.
  - `launchTarget()` still returns the engine base.
  - New `routed(_ target:, session:) -> LaunchTarget` applies the resolver to a `.local` target and returns `.cloud` unchanged.
  - `writeShimState` routes the base URL with `session: ProxyURL.sessionPlaceholder`.
- **`Localia/ProxyServiceManager.swift`**:
  - `ServiceRegistering` protocol. The live `SMAppServiceRegistrar` creates `SMAppService.agent(plistName: "fr.vincentlauriat.localia.proxy.plist")` on each call, because `SMAppService` isn't Sendable.
  - `ProxyState` enum and the `@MainActor` `ProxyServiceControlling` protocol (`state`, `isHealthy`, `ensureRunning`, `push`, `erase`, `uninstall`).
  - `InertProxyService`: never healthy, does nothing. It is the `AppDependencies` default, so tests reach engines direct.
  - `ProxyServiceManager` gets its registrar, fetch, app version, token URL, port, poll interval and deadline injected. `ensureRunning`:
    1. Concurrent calls share one in-flight Task.
    2. `.requiresApproval` gives `.unavailable("The Localia proxy is disabled in Login Items")` and no register.
    3. Any other non-enabled status registers once; a failure gives `.unavailable`.
    4. It polls `/localia/health` every 250 ms for up to 5 s.
    5. A version match, `"dev"`, or no app version gives `.running`.
    6. On a mismatch it unregisters and registers again, then polls until the new version answers or the deadline passes. If the version still differs it goes `.unavailable` with no second restart.
  - `push` and `erase` POST with `x-localia-token` (from `ProxyToken.load`) and expect 204. `push` logs errors; `erase` throws `ProxyServiceError`.
  - `uninstall` waits for a check in flight, unregisters, and sets the state to `.unknown`.
  - The live fetch is an ephemeral URLSession with a 1 s request timeout.
- **AppModel**:
  - `@Published private(set) var proxyFallbackActive` and a small `@MainActor RoutingSource`. It is captured by the controller's resolver closure through `MainActor.assumeIsolated`, because the controller is a `let` built in init. Its resolver is `RouteResolver(routes: settings.engineRoutes, proxyHealthy: !fallback && proxy.isHealthy)`.
  - `ensureProxy()`:
    - `.running` clears the fallback and pushes `settings.proxyConfig`, which covers ruling 8.
    - `.unavailable` sets `proxyFallbackActive = true`.
    - It calls `refreshShim()` when health flips or the fallback turns on.
  - Where it is called:
    - `start()` calls it in a non-blocking Task. `start()` isn't run in tests.
    - `handleStart` (`localia://start`) calls it in a non-blocking Task, so it stays off the model-load path.
    - `launch` calls it only when the state is still `.unknown`, so a launch in the first seconds doesn't silently route direct. Right after `sessionID` is created, it rewrites the target with `controller.routed(target, session: sessionID.uuidString)`. That is before `prepareConfig` and `tool.command`, so Codex/OpenCode/Pi configs use the routed URL too.
  - `removeFromShell()` calls `proxy.uninstall()` after the shell block is removed.
- **Services.swift**: `var proxy: any ProxyServiceControlling = InertProxyService()`, and `live()` passes `ProxyServiceManager()`.

## Tests and results

- RED, LocalModeControllerTests (tests written before the controller change): compile failure, `error: extra argument 'routes' in call` and `value of type 'LocalModeController' has no member 'routed'`.
- RED, ProxyServiceManagerTests (implementation file moved aside, then `xcodegen` and `xcodebuild -only-testing`): `error: cannot find type 'ServiceRegistering' in scope`, `cannot find type 'ProxyServiceManager' in scope`.
- GREEN:
  - `swift test --filter LocalModeControllerTests`: `Executed 18 tests, with 0 failures` (15 existing and 3 new: `test_target_usesProxyURL_whenHealthy`, `test_target_usesEngineURL_whenUnhealthy`, `test_shimState_usesPlaceholderSession`).
  - Full `swift test`: see Fix round 1. The first run reported `2 failures (0 unexpected)`, and the original report was wrong to call them expected failures. Nine later runs show 0 failures.
  - `-only-testing:LocaliaTests/ProxyServiceManagerTests`: `Executed 11 tests, with 0 failures`, `** TEST SUCCEEDED **`. This includes `test_versionMismatch_restarts` (fake registrar starts `.enabled`, stub answers "5" then "6": unregister ×1, register ×1, state `.running("6")`) and `test_registerFailure_isUnavailable`. Other cases: still-differs → unavailable with no second restart, notRegistered → register → running, dev version matches, Login Items disabled → no register, no answer, concurrent checks share one restart, push/erase token and body, erase without token, uninstall.
  - Full `xcodebuild test -scheme Localia`: `Executed 100 tests, with 0 failures`, `** TEST SUCCEEDED **`. Existing AppModelTests that assert direct `engine.baseURL` (lines 108 and 151) pass unchanged.
- `test_proxySettings_defaultsClampAndRoundTrip` was added to `SettingsStoreTests` after the settings code was written, so it has no RED run. It passes.
- No new compiler warnings in the changed files. The real LaunchAgent is never registered in tests: fakes are used, `start()` is skipped under tests, and the AppModel tests get `InertProxyService`.

## Files changed

- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Localia/ProxyServiceManager.swift (new)
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/LocaliaTests/ProxyServiceManagerTests.swift (new)
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Localia/AppModel.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Localia/Services.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Packages/LocaliaCore/Sources/LocaliaCore/LocalMode/LocalModeController.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Packages/LocaliaCore/Sources/LocaliaCore/Proxy/ProxyConfig.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Packages/LocaliaCore/Sources/LocaliaCore/Settings/SettingsStore.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Packages/LocaliaCore/Tests/LocaliaCoreTests/LocalModeControllerTests.swift
- /Users/vincentlauriat/DevApps/LocalAITools/Localia-proxy/Packages/LocaliaCore/Tests/LocaliaCoreTests/HealthSettingsTests.swift

## Deviations and self-review

- **Fetch signature.** The fetch is `@Sendable (URLRequest) async throws -> (Data, Int)`, not `(URL)`. Config and erase need POST, a body and the token header.
- **Who pushes the config.** AppModel pushes it in `ensureProxy()` on `.running`, not the manager. That keeps the manager free of settings and lets a Task 10 fake observe `push`.
- **New `routed(_:session:)`.** The brief says the controller "uses the resolver for the launch target", but the controller has no session id. So `launchTarget()` returns the engine base, and AppModel calls `routed` once `sessionID` exists.
- **Launch before the first check.** A launch while the proxy state is still `.unknown` awaits `ensureProxy()`. That can delay it by up to 5 s, and only during the first startup check. The alternative was to route it direct silently.
- **Strings.** The new user-facing strings (`unavailable` reasons, `ProxyServiceError`) are in English only. Task 10 owns the catalogs.

## Concerns

1. **Shim is broken for proxied engines until Task 9 lands.** In the `everyClaude` scope, shim state now carries `http://127.0.0.1:11438/s/@LOCALIA_SESSION@/<engine>`. The shim doesn't substitute the placeholder yet, and `@` fails `isValidSession`, so terminal `claude` and its probe would get 404s. Task 9 covers both the substitution and `proxyprobe`, so this is an accepted intermediate state. Don't ship between the two tasks.
2. **`uninstall()` only lasts until the next check.** After "Remove Localia from My Shell", the next app start or a launch calls `ensureRunning` and registers the agent again. Deleting the app right after removal leaves no agent, which is the goal. If the uninstall should stick, a persisted "proxy disabled" flag is needed (Task 10 decision).
3. **No retry when unavailable.** Once `.unavailable`, routing stays direct (`proxyFallbackActive`) until the next `ensureProxy()` from start or `localia://start`. Launches don't retry the check. A retry or watchdog could come with the banner in Task 10.

## Fix round 1

**Finding.** The first full `swift test` run reported `Executed 354 tests, with 5 tests skipped and 2 failures (0 unexpected)`. The report called these expected failures (XCTExpectFailure). That was wrong: no XCTExpectFailure or withKnownIssue exists in the repo, and "(0 unexpected)" only means no uncaught errors were thrown. They were ordinary assertion failures.

**Names of the two tests.** I can't recover them. That first run's output was piped through `grep … | tail -8`, which kept only the summary lines, and the log no longer exists. This is my error: I read a failing summary as a pass without checking it.

**Reproduction attempts.** I ran the full `swift test` the way the coordinator asked (`grep -E "error:|failed|Executed"`) and kept each full log.
- HEAD `9b0bbae`: 9 runs, all `Executed 354 tests, with 5 tests skipped and 0 failures (0 unexpected)` (44.5 to 48.0 s).
- Base `2dfac3a`, in a temporary worktree at `/tmp/l-base`, since removed: 3 runs, all `Executed 350 tests, with 5 tests skipped and 0 failures (0 unexpected)` (44.6 to 45.4 s).
- No failure line (`error: -[`, `' failed`) appears in any of the 12 logs.

**Assessment.** The failures were transient. The failing run took 61.2 s where clean runs take about 45 s, which points to a loaded machine during that run. The probable candidates are tests that rely on fixed sleeps or random ports, none of which this commit touches:
- `AnthropicGatewayTests.test_slowClient_isDropped_andConnectionsAreCapped` and `test_refusalsAreCappedToo`: 100 to 150 ms sleeps, a `< 1.5 s` assertion, and random ports in 30000...50000.
- `DownloaderTests.test_cancel_removesPartial`: a 300 ms sleep.
- `ProxyServerTests`: a 100 ms sleep at line 392.

This is not proven, because the failing output is lost. The commit changes no test code or source code under those suites. The only core changes are LocalModeController routing, SettingsStore proxy settings, the `ProxyConfig` init and their tests, and all of those pass in every run. No code change was made in this round. Changing code against a failure I can't reproduce would be guessing.

Final run (HEAD `9b0bbae`), last of the nine:
```
$ cd Packages/LocaliaCore && swift test 2>&1 | grep -E "error:|failed|Executed"
	 Executed 354 tests, with 5 tests skipped and 0 failures (0 unexpected) in 45.940 (45.985) seconds
```
