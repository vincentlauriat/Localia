import Foundation
import Darwin

public enum SpeedMeterError: Error, Equatable {
    case badResponse(String)
    case unsupportedEngine
}

/// Measures real generation speed and resident memory of a loaded model with a short 64-token generation.
/// llmfit's estimates are only a prior; this is the ground truth that calibrates recommendations.
public struct SpeedMeter: Sendable {
    public static let probeTokens = 64
    public static let probePrompt = "Write a short story about a lighthouse keeper."

    private let session: URLSession
    private let rssProvider: @Sendable (Int32) -> Double?

    /// - Parameter rssBytes: resident set size in bytes for a pid (default: `proc_pid_rusage`).
    public init(session: URLSession = .shared,
                rssBytes: @escaping @Sendable (Int32) -> Double? = SpeedMeter.systemRSSBytes) {
        self.session = session
        self.rssProvider = rssBytes
    }

    /// Memory is reported in GiB, like `MachineProfile`.
    public func measure(engine: any Engine, model: String) async throws -> (tps: Double, memoryGB: Double) {
        switch engine.id {
        case .ollama: return try await measureOllama(engine, model)
        case .llamaCpp: return try await measureLlama(engine, model)
        }
    }

    private static let gib = 1024.0 * 1024.0 * 1024.0

    private func measureOllama(_ engine: any Engine, _ model: String) async throws -> (Double, Double) {
        let body: [String: Any] = ["model": model, "prompt": Self.probePrompt, "stream": false,
                                   "keep_alive": OllamaEngine.keepAlive,
                                   "options": ["num_predict": Self.probeTokens]]
        let obj = try await postJSON(engine.baseURL.appendingPathComponent("api/generate"), body)
        if let err = obj["error"] as? String { throw EngineError.server(err) }
        guard let count = (obj["eval_count"] as? NSNumber)?.doubleValue,
              let dur = (obj["eval_duration"] as? NSNumber)?.doubleValue, count > 0, dur > 0
        else { throw SpeedMeterError.badResponse("missing eval_count / eval_duration") }
        let tps = count / (dur * 1e-9)

        var req = URLRequest(url: engine.baseURL.appendingPathComponent("api/ps"))
        req.timeoutInterval = 10
        let (data, _) = try await session.data(for: req)
        let ps = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let models = ps["models"] as? [[String: Any]] ?? []
        let entry = models.first { ($0["name"] as? String) == model || ($0["model"] as? String) == model }
        guard let size = (entry?["size"] as? NSNumber)?.doubleValue else {
            throw SpeedMeterError.badResponse("model not listed by /api/ps")
        }
        return (tps, size / Self.gib)
    }

    private func measureLlama(_ engine: any Engine, _ model: String) async throws -> (Double, Double) {
        let body: [String: Any] = ["prompt": Self.probePrompt, "n_predict": Self.probeTokens,
                                   "stream": false, "cache_prompt": false]
        let obj = try await postJSON(engine.baseURL.appendingPathComponent("completion"), body)
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { throw EngineError.server(m) }
        guard let timings = obj["timings"] as? [String: Any],
              let tps = (timings["predicted_per_second"] as? NSNumber)?.doubleValue, tps > 0
        else { throw SpeedMeterError.badResponse("missing timings.predicted_per_second") }

        // Note: RSS may undercount mmapped / Metal-resident weights, so this memory figure is a lower bound.
        guard let llama = engine as? LlamaCppEngine else { throw SpeedMeterError.unsupportedEngine }
        guard let pid = await llama.serverPID(), let rss = rssProvider(pid) else {
            throw SpeedMeterError.badResponse("llama-server pid / RSS unavailable")
        }
        return (tps, rss / Self.gib)
    }

    private func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EngineError.http(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Resident set size of `pid` in bytes, or nil if it cannot be read.
    public static let systemRSSBytes: @Sendable (Int32) -> Double? = { pid in
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? Double(info.ri_resident_size) : nil
    }
}

public enum SpeedCalibration {
    /// median(measured / unscaled estimate) over models present in both maps; nil when none.
    /// `estimates` must be the UNSCALED llmfit estimates (recommend with `Measurements()`), or the ratio compounds.
    public static func speedRatio(measured: [String: Double], estimates: [String: Double]) -> Double? {
        let ratios = measured.compactMap { id, tps -> Double? in
            guard let e = estimates[id], e > 0, tps > 0 else { return nil }
            return tps / e
        }.sorted()
        guard !ratios.isEmpty else { return nil }
        let mid = ratios.count / 2
        return ratios.count % 2 == 1 ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2
    }
}
