import Foundation

/// What HFCatalog needs from the rest of the app to grade a Hugging Face GGUF like a llmfit row.
public struct HFCatalogContext: Sendable, Equatable {
    /// `MachineProfile.usablePoolGB`.
    public var poolGB: Double
    /// tok/s × weights GB on this Mac (see `HFCatalog.speedConstant(rows:)`).
    public var speedConstant: Double
    public var speedRatio: Double?
    /// GGUF repos already listed from llmfit, compared case-insensitively. Recent only: search shows them.
    public var knownRepos: Set<String>
    /// Base models already listed from llmfit (llmfit ids), compared case-insensitively. Recent only.
    public var knownBases: Set<String>

    public init(poolGB: Double, speedConstant: Double, speedRatio: Double?, knownRepos: Set<String>,
                knownBases: Set<String> = []) {
        self.poolGB = poolGB; self.speedConstant = speedConstant; self.speedRatio = speedRatio
        self.knownRepos = Set(knownRepos.map { $0.lowercased() })
        self.knownBases = Set(knownBases.map { $0.lowercased() })
    }
}

/// A Hugging Face GGUF graded for this Mac (`candidate.fits` is false when it does not fit).
/// Not rated by llmfit: no quality score.
public struct HFCatalogEntry: Identifiable, Sendable, Equatable {
    public let candidate: ModelCandidate
    /// ISO 8601, as the Hub returns it.
    public let createdAt: String?
    public let downloads: Int

    public init(candidate: ModelCandidate, createdAt: String?, downloads: Int) {
        self.candidate = candidate; self.createdAt = createdAt; self.downloads = downloads
    }

    public var id: String { candidate.id }
    /// The fit grade, nil when the model does not fit.
    public var verdict: Fit? { candidate.fits ? candidate.fit : nil }
}

/// Recent GGUFs from trusted providers and free-text search on the Hugging Face Hub, mapped to candidates
/// with Localia's own estimates, built like llmfit's: Q4_K_M weights + exact KV cache + runtime overhead.
public struct HFCatalog: Sendable {
    static let api = "https://huggingface.co/api/models"
    static let expand = ["gguf", "downloads", "createdAt", "cardData", "siblings"]
    /// Memory overhead per billion parameters when the base config cannot be read (gated base).
    static let fallbackOverheadPerB = 1.3
    /// Compute buffers and runtime: llmfit's memory_required_gb is exactly weights + KV + 0.5
    /// (Qwen3-8B, Qwen2.5-7B, Llama-3.1-8B, Mistral-7B, Qwen3-14B, Qwen3-30B-A3B rows of llmfit 1.1.20).
    static let runtimeOverheadGB = Recommender.runtimeOverheadGB
    /// Vision projector (`mmproj-*.gguf`, about 0.8–1.2 GB in BF16), counted when the repo ships one.
    static let mmprojGB = 1.2
    /// llmfit's MoE speed against the dense constant: Qwen3-30B-A3B gives 21 tok/s × 3.35B active × 1.05
    /// bytes per param (Q8_0) ≈ 73, against a dense median of 88.7.
    static let moeSpeedFactor = 0.82
    static let maxConcurrentConfigs = 6

    private let session: URLSession
    private let configs: ConfigCache

    public init(session: URLSession = .shared) {
        self.session = session
        self.configs = ConfigCache()
    }

    /// Newest GGUFs of the trusted providers that fit, one per base model, tool-capable first, then newest
    /// first. Throws only when every provider is unreachable.
    public func recent(_ ctx: HFCatalogContext) async throws -> [HFCatalogEntry] {
        let lists = await withTaskGroup(of: Result<[HFModel], Error>.self) { group in
            for p in Recommender.trustedGGUFProviders {
                group.addTask {
                    do { return .success(try await self.list([("author", p), ("sort", "createdAt"), ("limit", "30")])) }
                    catch { return .failure(error) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let failures = lists.compactMap { r -> Error? in if case .failure(let e) = r { e } else { nil } }
        if failures.count == lists.count, let e = failures.first { throw e }
        let models = lists.compactMap { try? $0.get() }.flatMap { $0 }.filter {
            !ctx.knownRepos.contains($0.id.lowercased()) && !ctx.knownBases.contains($0.baseKey)
        }
        return await entries(Self.onePerBase(models), ctx).filter(\.candidate.fits).sorted {
            if $0.candidate.supportsTools != $1.candidate.supportsTools { return $0.candidate.supportsTools }
            return ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
    }

    /// Any author's GGUFs matching `query`, most downloaded first, including those that do not fit and those
    /// llmfit already lists (the caller may swap in llmfit's rated candidate).
    public func search(_ query: String, _ ctx: HFCatalogContext) async throws -> [HFCatalogEntry] {
        let models = try await list([("search", query), ("sort", "downloads"), ("limit", "40")])
        return await entries(models, ctx).sorted { $0.downloads > $1.downloads }
    }

    /// Median of `estimated_tps × weights GB` over llmfit rows: llmfit's speed model is bandwidth-bound,
    /// so this product is a per-Mac constant (about 88.7 on an M5 24 GB).
    public static func speedConstant(rows: [LlmfitRow]) -> Double? {
        let ks = rows.compactMap { r -> Double? in
            guard let tps = r.estimatedTPS, let p = r.paramsB, let q = r.bestQuant,
                  let bpp = Recommender.bytesPerParam[q] else { return nil }
            return tps * p * bpp
        }.sorted()
        guard !ks.isEmpty else { return nil }
        let mid = ks.count / 2
        return ks.count % 2 == 0 ? (ks[mid - 1] + ks[mid]) / 2 : ks[mid]
    }

    // MARK: - Mapping

    /// Keeps one usable repo per base model, preferring providers in `Recommender.trustedGGUFProviders` order.
    static func onePerBase(_ models: [HFModel]) -> [HFModel] {
        func rank(_ m: HFModel) -> Int {
            Recommender.trustedGGUFProviders.firstIndex(of: m.provider) ?? Recommender.trustedGGUFProviders.count
        }
        var best: [String: HFModel] = [:]
        var order: [String] = []
        for m in models where usable(m) {
            if let current = best[m.baseKey] {
                if rank(m) < rank(current) { best[m.baseKey] = m }
            } else {
                best[m.baseKey] = m; order.append(m.baseKey)
            }
        }
        return order.compactMap { best[$0] }
    }

    private func entries(_ models: [HFModel], _ ctx: HFCatalogContext) async -> [HFCatalogEntry] {
        var seen = Set<String>()
        let kept = models.filter { Self.usable($0) && seen.insert($0.id.lowercased()).inserted }
        let shapes = await modelShapes(Set(kept.compactMap(\.baseModel)))
        return kept.compactMap { Self.entry($0, shape: $0.baseModel.flatMap { shapes[$0] }, ctx) }
    }

    /// A chat GGUF with a Q4_K_M file, size and context known, and not filtered out by name.
    static func usable(_ m: HFModel) -> Bool {
        guard let g = m.gguf, g.total != nil, g.contextLength != nil, !(g.chatTemplate ?? "").isEmpty,
              m.hasQ4KM else { return false }
        return !isExcluded(m)
    }

    /// Recommender's name filter, applied to the architecture too: speculative-decoding drafts (`dflash`)
    /// are published under the big model's repo name. Test repos are left out as well.
    static func isExcluded(_ m: HFModel) -> Bool {
        Recommender.isExcludedName(m.id) || Recommender.isExcludedName(m.gguf?.architecture ?? "")
            || m.id.lowercased().contains("for-testing")
    }

    /// Active parameters (billions) written in the name, as in `Qwen3-30B-A3B`.
    static func activeParamsFromName(_ name: String) -> Double? {
        guard let r = name.range(of: #"-A(\d+(\.\d+)?)B"#, options: .regularExpression) else { return nil }
        return Double(name[r].dropFirst(2).dropLast())
    }

    static func looksMoE(_ m: HFModel) -> Bool {
        activeParamsFromName(m.id) != nil || (m.gguf?.architecture ?? "").lowercased().contains("moe")
    }

    static func entry(_ m: HFModel, shape: ModelShape?, _ ctx: HFCatalogContext) -> HFCatalogEntry? {
        guard let total = m.gguf?.total, let rawContext = m.gguf?.contextLength,
              let bpp = Recommender.bytesPerParam[LocaliaConstants.defaultQuant] else { return nil }
        let paramsB = total / 1e9
        let weightsGB = paramsB * bpp
        let context = min(LocaliaConstants.localContextTokens, rawContext)
        let projector = m.hasMMProj ? mmprojGB : 0
        let kv = shape?.kvGiB(context: context)
        let overhead = projector + (kv == nil ? fallbackOverheadPerB * paramsB : runtimeOverheadGB)
        let memoryGB = weightsGB + (kv ?? 0) + overhead

        // Speed is bound by the bytes read per token: the active parameters for a mixture of experts.
        let active = shape?.activeParamsB(totalB: paramsB) ?? activeParamsFromName(m.id)
        let ratio = ctx.speedRatio ?? 1
        let tps = active.map { ctx.speedConstant * moeSpeedFactor / ($0 * bpp) * ratio }
            ?? ctx.speedConstant / weightsGB * ratio
        // An MoE whose active size is unknown is far faster than its total size says: never call it slow.
        let slow = tps < Double(LocaliaConstants.speedFloorTPS) && !(active == nil && looksMoE(m))

        let verdict = grade(memoryGB: memoryGB, poolGB: ctx.poolGB)
        let name = String(m.id.split(separator: "/").last ?? Substring(m.id))
        let display = name.hasSuffix("-GGUF") ? String(name.dropLast(5)) : name
        let candidate = ModelCandidate(
            id: m.id, displayName: display, ggufRepo: m.id, quant: LocaliaConstants.defaultQuant,
            weightsGB: weightsGB, memoryGB: memoryGB, estimatedTPS: tps,
            fit: verdict ?? .marginal, slow: slow,
            supportsTools: m.gguf?.chatTemplate?.contains("tools") ?? false,
            memoryIsMeasured: false, speedIsMeasured: false, quality: 0,
            source: .huggingface, memoryIsEstimate: shape == nil, fits: verdict != nil,
            kvCacheGB: kv, overheadGB: kv == nil ? nil : overhead, paramsB: paramsB)
        return HFCatalogEntry(candidate: candidate, createdAt: m.createdAt, downloads: m.downloads ?? 0)
    }

    /// Same thresholds as `Recommender`.
    static func grade(memoryGB: Double, poolGB: Double) -> Fit? {
        let ratio = memoryGB / poolGB
        if ratio <= 0.60 { return .perfect }
        if ratio <= 0.85 { return .good }
        if ratio <= 0.98 { return .marginal }
        return nil
    }

    // MARK: - Network

    private func list(_ params: [(String, String)]) async throws -> [HFModel] {
        var comps = URLComponents(string: Self.api)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
            + [URLQueryItem(name: "filter", value: "gguf"), URLQueryItem(name: "direction", value: "-1")]
            + Self.expand.map { URLQueryItem(name: "expand[]", value: $0) }
        // URLComponents leaves "+" alone, which the Hub would read as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw EngineError.http(0) }
        let (data, resp) = try await session.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw EngineError.http(code) }
        return try JSONDecoder().decode([HFModel].self, from: data)
    }

    /// Shapes of the base models, at most `maxConcurrentConfigs` lookups at a time.
    private func modelShapes(_ bases: Set<String>) async -> [String: ModelShape] {
        var out: [String: ModelShape] = [:]
        await withTaskGroup(of: (String, ModelShape?).self) { group in
            var pending = bases.makeIterator()
            func addNext() -> Bool {
                guard let b = pending.next() else { return false }
                group.addTask { (b, await self.modelShape(base: b)) }
                return true
            }
            for _ in 0..<Self.maxConcurrentConfigs { if !addNext() { break } }
            for await (b, shape) in group {
                if let shape { out[b] = shape }
                _ = addNext()
            }
        }
        return out
    }

    private func modelShape(base: String) async -> ModelShape? {
        if let cached = await configs.get(base) { return cached }
        guard let url = URL(string: "https://huggingface.co/\(base)/resolve/main/config.json"),
              let (data, resp) = try? await session.data(from: url) else {
            return nil   // no answer (offline, cancelled): not cached, retried next time
        }
        var shape: ModelShape?
        if (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shape = ModelShape(config: obj)
        }
        // Answered but unreadable (gated, missing) is cached too: it will not become readable during this run.
        await configs.set(base, shape)
        return shape
    }

    /// What the base `config.json` says about memory (KV cache) and speed (experts).
    struct ModelShape: Sendable, Equatable {
        struct Experts: Sendable, Equatable {
            let count: Int, perToken: Int, hidden: Int, ffn: Int
        }
        let layers: Int, kvHeads: Int, headDim: Int
        let experts: Experts?

        init(layers: Int, kvHeads: Int, headDim: Int, experts: Experts? = nil) {
            self.layers = layers; self.kvHeads = kvHeads; self.headDim = headDim; self.experts = experts
        }

        /// Reads `config.json`, preferring `text_config` (multimodal models nest the language model there).
        init?(config: [String: Any]) {
            let c = config["text_config"] as? [String: Any] ?? config
            func int(_ keys: String...) -> Int? { keys.lazy.compactMap { (c[$0] as? NSNumber)?.intValue }.first }
            guard let layers = int("num_hidden_layers"), let heads = int("num_attention_heads"), heads > 0 else { return nil }
            let hidden = int("hidden_size")
            let headDim = int("head_dim") ?? hidden.map { $0 / heads }
            guard let headDim, headDim > 0 else { return nil }
            var experts: Experts?
            if let n = int("num_experts", "num_local_experts", "n_routed_experts"), n > 1,
               let k = int("num_experts_per_tok", "num_experts_per_token", "moe_topk"), k > 0, k < n,
               let hidden, let ffn = int("moe_intermediate_size", "intermediate_size") {
                experts = Experts(count: n, perToken: k, hidden: hidden, ffn: ffn)
            }
            self.init(layers: layers, kvHeads: int("num_key_value_heads") ?? heads, headDim: headDim, experts: experts)
        }

        /// K and V, fp16, for `context` tokens, in GiB.
        func kvGiB(context: Int) -> Double {
            2.0 * Double(layers) * Double(kvHeads) * Double(headDim) * 2 * Double(context) / 1_073_741_824
        }

        /// Total minus the experts a token does not use (gated FFN: 3 × hidden × ffn weights per expert
        /// per layer). Nil for a dense model.
        func activeParamsB(totalB: Double) -> Double? {
            guard let e = experts else { return nil }
            let idle = Double(e.count - e.perToken) * 3 * Double(e.hidden) * Double(e.ffn) * Double(layers) / 1e9
            let active = totalB - idle
            return active > 0 ? active : nil
        }
    }

    // MARK: - Hub JSON

    struct HFModel: Decodable, Sendable {
        struct GGUF: Decodable, Sendable {
            let total: Double?
            let architecture: String?
            let contextLength: Int?
            let chatTemplate: String?
            enum CodingKeys: String, CodingKey {
                case total, architecture
                case contextLength = "context_length"
                case chatTemplate = "chat_template"
            }
        }
        let id: String
        let downloads: Int?
        let createdAt: String?
        let gguf: GGUF?
        /// First `cardData.base_model` (a string or a list on the Hub).
        let baseModel: String?
        /// Repo file names (`siblings[].rfilename`).
        let files: [String]

        var provider: String { String(id.split(separator: "/").first ?? "") }

        /// Base model, else the repo name without provider, `-GGUF` and bartowski's `org_` prefix.
        var baseKey: String {
            if let b = baseModel { return b.lowercased() }
            var name = String(id.split(separator: "/").last ?? Substring(id)).lowercased()
            if name.hasSuffix("-gguf") { name = String(name.dropLast(5)) }
            if let u = name.firstIndex(of: "_") { name = String(name[name.index(after: u)...]) }
            return name
        }

        var hasQ4KM: Bool {
            files.contains { $0.lowercased().hasSuffix(".gguf") && $0.uppercased().contains("Q4_K_M") }
        }

        var hasMMProj: Bool {
            files.contains { $0.split(separator: "/").last?.lowercased().hasPrefix("mmproj") ?? false }
        }

        enum CodingKeys: String, CodingKey { case id, downloads, createdAt, gguf, cardData, siblings }
        enum CardKeys: String, CodingKey { case baseModel = "base_model" }
        struct Sibling: Decodable { let rfilename: String }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            downloads = try? c.decodeIfPresent(Int.self, forKey: .downloads)
            createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
            gguf = try? c.decodeIfPresent(GGUF.self, forKey: .gguf)
            files = ((try? c.decodeIfPresent([Sibling].self, forKey: .siblings)) ?? []).map(\.rfilename)
            let card = try? c.nestedContainer(keyedBy: CardKeys.self, forKey: .cardData)
            if let s = try? card?.decodeIfPresent(String.self, forKey: .baseModel) { baseModel = s }
            else { baseModel = (try? card?.decodeIfPresent([String].self, forKey: .baseModel))?.first }
        }
    }
}

private actor ConfigCache {
    private var shapes: [String: HFCatalog.ModelShape?] = [:]
    /// Outer nil: never looked up; inner nil: unreadable.
    func get(_ base: String) -> HFCatalog.ModelShape?? { shapes[base] }
    func set(_ base: String, _ shape: HFCatalog.ModelShape?) { shapes[base] = .some(shape) }
}
