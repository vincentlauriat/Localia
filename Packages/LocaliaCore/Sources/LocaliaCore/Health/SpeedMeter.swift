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
    private let footprintProvider: @Sendable (Int32) -> Double?

    /// - Parameters:
    ///   - rssBytes: resident set size in bytes for a pid (default: `proc_pid_rusage`).
    ///   - footprintBytes: physical footprint in bytes for a pid, which counts Metal buffers (MLX).
    public init(session: URLSession = .shared,
                rssBytes: @escaping @Sendable (Int32) -> Double? = SpeedMeter.systemRSSBytes,
                footprintBytes: @escaping @Sendable (Int32) -> Double? = SpeedMeter.systemFootprintBytes) {
        self.session = session
        self.rssProvider = rssBytes
        self.footprintProvider = footprintBytes
    }

    /// Memory is reported in GiB, like `MachineProfile`. `loadedByLocalia`: only a model Localia loaded
    /// gets Localia's keep_alive; for anyone else's the probe sends none, so it does not override theirs.
    public func measure(engine: any Engine, model: String, loadedByLocalia: Bool) async throws -> (tps: Double, memoryGB: Double) {
        switch engine.id {
        case .ollama: return try await measureOllama(engine, model, keepAlive: loadedByLocalia)
        case .llamaCpp: return try await measureLlama(engine, model)
        case .mlx: return try await measureMLX(engine)
        }
    }

    private static let gib = 1024.0 * 1024.0 * 1024.0

    private func measureOllama(_ engine: any Engine, _ model: String, keepAlive: Bool) async throws -> (Double, Double) {
        var body: [String: Any] = ["model": model, "prompt": Self.probePrompt, "stream": false,
                                   "options": ["num_predict": Self.probeTokens]]
        if keepAlive { body["keep_alive"] = OllamaEngine.keepAlive }
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

    /// `mlx_lm.server` reports no timings: stream the probe and time from the first to the last token, so the
    /// prompt's prefill is not counted.
    private func measureMLX(_ engine: any Engine) async throws -> (Double, Double) {
        guard let mlx = engine as? MLXEngine else { throw SpeedMeterError.unsupportedEngine }
        var req = URLRequest(url: mlx.upstreamURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "default_model", "stream": true, "stream_options": ["include_usage": true],
            "max_tokens": Self.probeTokens, "temperature": 0,
            "messages": [["role": "user", "content": Self.probePrompt]]] as [String: Any])
        let (bytes, resp) = try await session.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EngineError.http(status) }
        var first: Date?, last: Date?
        var chunks = 0
        var completion: Int?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let obj = try? JSONSerialization.jsonObject(
                with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any] else { continue }
            if let u = obj["usage"] as? [String: Any], let c = AnthropicTranslation.nonNegativeInt(u["completion_tokens"]) {
                completion = c
            }
            guard let delta = ((obj["choices"] as? [Any])?.first as? [String: Any])?["delta"] as? [String: Any],
                  delta["content"] != nil || delta["reasoning"] != nil else { continue }
            let now = Date()
            if first == nil { first = now }
            last = now
            chunks += 1
        }
        let tokens = completion ?? chunks
        guard let first, let last, tokens > 1 else { throw SpeedMeterError.badResponse("too few tokens streamed") }
        let tps = Double(tokens - 1) / max(last.timeIntervalSince(first), 0.001)
        // MLX keeps the weights in Metal buffers, which the resident size misses: use the physical footprint.
        guard let pid = await mlx.serverPID(), let bytes = footprintProvider(pid) else {
            throw SpeedMeterError.badResponse("mlx_lm.server pid / footprint unavailable")
        }
        return (tps, bytes / Self.gib)
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

    /// Physical footprint of `pid` in bytes (what Activity Monitor shows as Memory), or nil if it cannot be read.
    public static let systemFootprintBytes: @Sendable (Int32) -> Double? = { pid in
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) : nil
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
    /// median(measured / unscaled estimate) over models present in both maps; nil when fewer than two.
    /// `estimates` must be the UNSCALED llmfit estimates (recommend with `Measurements()`), or the ratio compounds.
    public static func speedRatio(measured: [String: Double], estimates: [String: Double]) -> Double? {
        let ratios = measured.compactMap { id, tps -> Double? in
            guard let e = estimates[id], e > 0, tps > 0 else { return nil }
            return tps / e
        }.sorted()
        // One model is not a trend (it may have been measured under memory pressure): need at least two.
        guard ratios.count >= 2 else { return nil }
        let mid = ratios.count / 2
        return ratios.count % 2 == 1 ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2
    }
}
