import XCTest

/// Every `String(localized:)` key of the proxy manager has a French translation in the catalog, so a reason
/// shown in Settings is never English in a French UI.
final class ProxyStringsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Interpolations (`\(...)` in source, `%@` / `%lld` in the catalog) compare equal once masked.
    private static func masked(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "\u{0}", options: .regularExpression)
            .replacingOccurrences(of: "%lld", with: "\u{0}").replacingOccurrences(of: "%@", with: "\u{0}")
    }

    func test_everyProxyManagerStringHasAFrenchTranslation() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Localia/ProxyServiceManager.swift"),
                                encoding: .utf8)
        let keys = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*?)"\)"#)
            .matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        XCTAssertGreaterThanOrEqual(keys.count, 7)

        let data = try Data(contentsOf: Self.root.appendingPathComponent("Localia/Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var french: [String: String] = [:]
        for (key, entry) in strings {
            let loc = entry["localizations"] as? [String: Any]
            let unit = (loc?["fr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            if let v = unit?["value"] as? String, !v.isEmpty { french[Self.masked(key)] = v }
        }
        for key in keys {
            XCTAssertNotNil(french[Self.masked(key)], "no fr translation for: \(key)")
        }
    }
}
