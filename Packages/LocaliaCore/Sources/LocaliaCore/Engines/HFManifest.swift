import Foundation

/// Reads the Hugging Face (Docker-registry style) manifest of a GGUF repo to show the download size before pulling.
public struct HFManifest: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private struct Manifest: Decodable {
        struct Layer: Decodable { let mediaType: String; let size: Int64 }
        let layers: [Layer]
    }

    /// Size in bytes of the manifest's `…model` layer.
    public func size(repo: String, quant: String) async throws -> Int64 {
        guard let url = URL(string: "https://hf.co/v2/\(repo)/manifests/\(quant)") else { throw EngineError.http(0) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw EngineError.http(code) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let layer = manifest.layers.first(where: { $0.mediaType.hasSuffix(".model") }) else {
            throw EngineError.assetNotFound("model layer in manifest for \(repo):\(quant)")
        }
        return layer.size
    }
}
