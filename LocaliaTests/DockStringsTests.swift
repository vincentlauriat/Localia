import XCTest

/// Every `String(localized:)` key under `Localia/Views/Dock/` has a French translation in the catalog.
final class DockStringsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Interpolations (`\(...)` in source, `%@` / `%lld` in the catalog) compare equal once masked.
    private static func masked(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "\u{0}", options: .regularExpression)
            .replacingOccurrences(of: "%lld", with: "\u{0}").replacingOccurrences(of: "%@", with: "\u{0}")
    }

    func test_everyDockStringHasAFrenchTranslation() throws {
        let dir = Self.root.appendingPathComponent("Localia/Views/Dock")
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "(.*?)"\)"#)
        var keys: [String] = []
        for file in files {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            keys += pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        }

        let data = try Data(contentsOf: Self.root.appendingPathComponent("Localia/Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var french: [String: String] = [:]
        for (key, entry) in strings {
            let loc = entry["localizations"] as? [String: Any]
            let fr = loc?["fr"] as? [String: Any]
            // A plain translation, or plural variations / substitutions (their presence is the translation).
            let unit = fr?["stringUnit"] as? [String: Any]
            if let v = unit?["value"] as? String, !v.isEmpty { french[Self.masked(key)] = v }
            else if fr?["variations"] != nil || fr?["substitutions"] != nil { french[Self.masked(key)] = key }
        }
        for key in keys {
            XCTAssertNotNil(french[Self.masked(key)], "no fr translation for: \(key)")
        }
    }

    /// The route labels of the Log and the menu-bar trouble label have their exact French copy (RouteLabel
    /// lives in LocaliaCore, outside the folder the test above scans).
    func test_dockStrings_routeFrench() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Localia/Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        func french(_ key: String) -> String? {
            let loc = strings[key]?["localizations"] as? [String: Any]
            return ((loc?["fr"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        XCTAssertEqual(french("Route"), "Itinéraire")
        XCTAssertEqual(french("Fallback — engine stopped"), "Repli — moteur arrêté")
        XCTAssertEqual(french("Fixed engine"), "Moteur fixe")
        XCTAssertEqual(french("Localia, local AI in trouble"), "Localia, l'IA locale a un souci")
    }
}
