import Foundation

/// What HFCatalog needs from the rest of the app to grade a Hugging Face GGUF like a llmfit row.
public struct HFCatalogContext: Sendable, Equatable {
    /// `MachineProfile.usablePoolGB`.
    public var poolGB: Double
    /// tok/s × weights GB on this Mac (see `HFCatalog.speedConstant(rows:)`).
    public var speedConstant: Double
    public var speedRatio: Double?
    /// GGUF repos already listed from llmfit, compared case-insensitively.
    public var knownRepos: Set<String>

    public init(poolGB: Double, speedConstant: Double, speedRatio: Double?, knownRepos: Set<String>) {
        self.poolGB = poolGB; self.speedConstant = speedConstant; self.speedRatio = speedRatio
        self.knownRepos = Set(knownRepos.map { $0.lowercased() })
    }
}

/// A Hugging Face GGUF graded for this Mac. Not rated by llmfit: no quality score.
public struct HFCatalogEntry: Identifiable, Sendable, Equatable {
    public let candidate: ModelCandidate
    /// Nil when the model does not fit (`candidate.fit` is then meaningless).
    public let verdict: Fit?
    /// ISO 8601, as the Hub returns it.
    public let createdAt: String?
    public let downloads: Int

    public var id: String { candidate.id }
}

/// Recent GGUFs from trusted providers and free-text search on the Hugging Face Hub, mapped to candidates
/// with Localia's own estimates (Q4_K_M weights, exact KV cache when the base config is readable).
public struct HFCatalog: Sendable {
    static let api = "https://huggingface.co/api/models"
    static let expand = ["gguf", "downloads", "createdAt", "cardData"]
    /// Memory overhead per billion parameters when the base config cannot be read (gated base).
    static let fallbackOverheadPerB = 1.3
    static let maxConcurrentConfigs = 6

    private let session: URLSession
    private let configs: ConfigCache

    public init(session: URLSession = .shared) {
        self.session = session
        self.configs = ConfigCache()
    }

    /// Newest GGUFs of the trusted providers that fit, tool-capable first, then newest first.
    /// Throws only when every provider is unreachable.
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
        let models = lists.compactMap { try? $0.get() }.flatMap { $0 }
        return await entries(models, ctx).filter { $0.verdict != nil }.sorted {
            if $0.candidate.supportsTools != $1.candidate.supportsTools { return $0.candidate.supportsTools }
            return ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
    }

    /// Any author's GGUFs matching `query`, most downloaded first, including those that do not fit.
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

    private func entries(_ models: [HFModel], _ ctx: HFCatalogContext) async -> [HFCatalogEntry] {
        var seen = ctx.knownRepos
        let usable = models.filter { m in
            guard m.gguf?.total != nil, m.gguf?.contextLength != nil, !Self.isExcluded(m),
                  !seen.contains(m.id.lowercased()) else { return false }
            seen.insert(m.id.lowercased())
            return true
        }
        let shapes = await kvShapes(Set(usable.compactMap(\.baseModel)))
        return usable.compactMap { Self.entry($0, shape: $0.baseModel.flatMap { shapes[$0] }, ctx) }
    }

    /// Recommender's name filter, applied to the architecture too: speculative-decoding drafts (`dflash`)
    /// are published under the big model's repo name. Test repos are left out as well.
    static func isExcluded(_ m: HFModel) -> Bool {
        Recommender.isExcludedName(m.id) || Recommender.isExcludedName(m.gguf?.architecture ?? "")
            || m.id.lowercased().contains("for-testing")
    }

    static func entry(_ m: HFModel, shape: KVShape?, _ ctx: HFCatalogContext) -> HFCatalogEntry? {
        guard let total = m.gguf?.total, let rawContext = m.gguf?.contextLength,
              let bpp = Recommender.bytesPerParam[LocaliaConstants.defaultQuant] else { return nil }
        let paramsB = total / 1e9
        let weightsGB = paramsB * bpp
        let context = min(LocaliaConstants.localContextTokens, rawContext)
        let memoryGB = shape.map { weightsGB + $0.gib(context: context) } ?? weightsGB + fallbackOverheadPerB * paramsB
        let tps = ctx.speedConstant / weightsGB * (ctx.speedRatio ?? 1)
        let verdict = grade(memoryGB: memoryGB, poolGB: ctx.poolGB)
        let name = String(m.id.split(separator: "/").last ?? Substring(m.id))
        let display = name.hasSuffix("-GGUF") ? String(name.dropLast(5)) : name
        let candidate = ModelCandidate(
            id: m.id, displayName: display, ggufRepo: m.id, quant: LocaliaConstants.defaultQuant,
            weightsGB: weightsGB, memoryGB: memoryGB, estimatedTPS: tps, fit: verdict ?? .marginal,
            slow: tps < Double(LocaliaConstants.speedFloorTPS),
            supportsTools: m.gguf?.chatTemplate?.contains("tools") ?? false,
            memoryIsMeasured: false, speedIsMeasured: false, quality: 0,
            source: .huggingface, memoryIsEstimate: shape == nil)
        return HFCatalogEntry(candidate: candidate, verdict: verdict, createdAt: m.createdAt, downloads: m.downloads ?? 0)
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

    /// KV shapes of the base models, at most `maxConcurrentConfigs` lookups at a time.
    private func kvShapes(_ bases: Set<String>) async -> [String: KVShape] {
        var out: [String: KVShape] = [:]
        await withTaskGroup(of: (String, KVShape?).self) { group in
            var pending = bases.makeIterator()
            func addNext() -> Bool {
                guard let b = pending.next() else { return false }
                group.addTask { (b, await self.kvShape(base: b)) }
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

    private func kvShape(base: String) async -> KVShape? {
        if let cached = await configs.get(base) { return cached }
        var shape: KVShape?
        if let url = URL(string: "https://huggingface.co/\(base)/resolve/main/config.json"),
           let (data, resp) = try? await session.data(from: url),
           (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shape = KVShape(config: obj)
        }
        // Unreadable (gated, missing) is cached too: it will not become readable during this run.
        await configs.set(base, shape)
        return shape
    }

    /// The attention dimensions that size the KV cache.
    struct KVShape: Sendable, Equatable {
        let layers: Int, kvHeads: Int, headDim: Int

        init(layers: Int, kvHeads: Int, headDim: Int) {
            self.layers = layers; self.kvHeads = kvHeads; self.headDim = headDim
        }

        /// Reads `config.json`, preferring `text_config` (multimodal models nest the language model there).
        init?(config: [String: Any]) {
            let c = config["text_config"] as? [String: Any] ?? config
            func int(_ k: String) -> Int? { (c[k] as? NSNumber)?.intValue }
            guard let layers = int("num_hidden_layers"), let heads = int("num_attention_heads"), heads > 0 else { return nil }
            let headDim = int("head_dim") ?? int("hidden_size").map { $0 / heads }
            guard let headDim, headDim > 0 else { return nil }
            self.init(layers: layers, kvHeads: int("num_key_value_heads") ?? heads, headDim: headDim)
        }

        /// K and V, fp16, for `context` tokens, in GiB.
        func gib(context: Int) -> Double {
            2.0 * Double(layers) * Double(kvHeads) * Double(headDim) * 2 * Double(context) / 1_073_741_824
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

        enum CodingKeys: String, CodingKey { case id, downloads, createdAt, gguf, cardData }
        enum CardKeys: String, CodingKey { case baseModel = "base_model" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            downloads = try? c.decodeIfPresent(Int.self, forKey: .downloads)
            createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
            gguf = try? c.decodeIfPresent(GGUF.self, forKey: .gguf)
            let card = try? c.nestedContainer(keyedBy: CardKeys.self, forKey: .cardData)
            if let s = try? card?.decodeIfPresent(String.self, forKey: .baseModel) { baseModel = s }
            else { baseModel = (try? card?.decodeIfPresent([String].self, forKey: .baseModel))?.first }
        }
    }
}

private actor ConfigCache {
    private var shapes: [String: HFCatalog.KVShape?] = [:]
    /// Outer nil: never looked up; inner nil: unreadable.
    func get(_ base: String) -> HFCatalog.KVShape?? { shapes[base] }
    func set(_ base: String, _ shape: HFCatalog.KVShape?) { shapes[base] = .some(shape) }
}
