import Foundation
import LocaliaCore
import os

// LaunchAgent wrapping the Localia proxy. Registered by the app via SMAppService; launchd restarts it on exit.

let log = Logger(subsystem: "fr.vincentlauriat.localia", category: "proxy-service")

/// Refuses every redirect: the proxy relays the engine's answer unchanged.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Thread-safe holder of the current config.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProxyConfig
    init(_ value: ProxyConfig) { self.value = value }
    func get() -> ProxyConfig { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: ProxyConfig) { lock.lock(); value = v; lock.unlock() }
}

/// `CFBundleVersion` of the enclosing Localia.app (`.../Localia.app/Contents/MacOS/<exe>`), else "dev".
/// The path comes from the kernel: launchd (`BundleProgram`) passes a relative argv[0] with cwd `/`.
func appVersion() -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 else { return "dev" }
    let exe = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", let bundle = Bundle(url: app),
          let v = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !v.isEmpty else { return "dev" }
    return v
}

let dir = Paths.proxy()
let configURL = dir.appendingPathComponent("config.json")
let token: String
let store: UsageStore
do {
    token = try ProxyToken.loadOrCreate(at: dir.appendingPathComponent("token"))
    store = try UsageStore(url: dir.appendingPathComponent("usage.sqlite"), readOnly: false)
} catch {
    log.error("cannot open proxy data: \(String(describing: error), privacy: .public)")
    exit(1)
}

let box = ConfigBox(ProxyConfig.load(from: configURL))

let cfg = URLSessionConfiguration.ephemeral
cfg.httpCookieStorage = nil
cfg.urlCache = nil
cfg.httpMaximumConnectionsPerHost = 16
cfg.timeoutIntervalForRequest = 600
let session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)

func upstream(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

let server = ProxyServer(
    port: UInt16(LocaliaConstants.proxyPort),
    upstreams: [.ollama: upstream(LocaliaConstants.ollamaPort),
                .llamaCpp: upstream(LocaliaConstants.llamaServerPort),
                .mlx: upstream(LocaliaConstants.mlxGatewayPort)],
    store: store,
    config: { box.get() },
    setConfig: { new in
        try new.save(to: configURL)
        box.set(new)
    },
    token: token, sessionsDir: Paths.sessions(), version: appVersion(), session: session)

func purge() {
    do { try store.purge(now: Date(), retentionDays: box.get().retentionDays) }
    catch { log.error("purge failed: \(String(describing: error), privacy: .public)") }
}

Task {
    do { try await server.start() } catch {
        log.error("cannot listen on port \(LocaliaConstants.proxyPort): \(String(describing: error), privacy: .public)")
        exit(1)
    }
    log.info("proxy listening on 127.0.0.1:\(LocaliaConstants.proxyPort)")
}

purge()
let purgeTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
purgeTimer.schedule(deadline: .now() + 3600, repeating: 3600)
purgeTimer.setEventHandler { purge() }
purgeTimer.resume()

dispatchMain()
