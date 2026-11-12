import Foundation

/// Maps a candidate to its `mlx-community` 4-bit conversion, the way llmfit maps a base model to a GGUF repo.
/// The name follows mlx-community's convention (`<model>-4bit`); whether the repo exists is checked on the Hub.
public enum MLXRepo {
    public static let org = "mlx-community"
    public static let suffix = "-4bit"
    public static let quantLabel = "4-bit"

    /// `mlx-community/<model>-4bit`, nil when no model name can be derived.
    /// llmfit ids are base models (`Qwen/Qwen3-8B`); Hugging Face candidates are GGUF repos
    /// (`unsloth/Qwen3-8B-GGUF`, bartowski's `Qwen_Qwen3-8B-GGUF`).
    public static func repo(for c: ModelCandidate) -> String? {
        let parts = c.id.split(separator: "/")
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if c.source == .huggingface {
            if name.lowercased().hasSuffix("-gguf") { name = String(name.dropLast(5)) }
            if parts[0] == "bartowski", let u = name.firstIndex(of: "_") { name = String(name[name.index(after: u)...]) }
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        if parts[0] == Substring(org) { return c.id }
        return "\(org)/\(name)\(suffix)"
    }
}

/// Answers "does this MLX repo exist on the Hub?", with a cache. Unknown (offline) answers are not cached.
public actor MLXRepoResolver {
    private let session: URLSession
    private let apiBase: URL
    private var known: [String: Bool] = [:]

    public init(session: URLSession = .shared, apiBase: URL = URL(string: "https://huggingface.co/api/models")!) {
        self.session = session; self.apiBase = apiBase
    }

    /// True / false when the Hub answered, nil when it could not be asked.
    public func exists(_ repo: String) async -> Bool? {
        if let k = known[repo] { return k }
        guard LlamaCppEngine.isSafeRelativePath(repo) else { return false }
        var req = URLRequest(url: apiBase.appendingPathComponent(repo))
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        guard let (_, resp) = try? await session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        let answer: Bool
        switch code {
        case 200..<300: answer = true
        case 401, 403, 404: answer = false   // the Hub answers 401 for repos that do not exist
        default: return nil
        }
        known[repo] = answer
        return answer
    }
}
