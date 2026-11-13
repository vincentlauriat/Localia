import XCTest
@testable import Localia

final class FmtTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")

    func test_number_usesTheGivenLocaleSeparator() {
        XCTAssertEqual(Fmt.number(10.94, fractionDigits: 1, locale: en), "10.9")
        XCTAssertEqual(Fmt.number(10.94, fractionDigits: 1, locale: fr), "10,9")
    }

    func test_number_keepsFractionDigitsAndGrouping() {
        XCTAssertEqual(Fmt.number(48, fractionDigits: 1, locale: en), "48.0")
        XCTAssertEqual(Fmt.number(48, fractionDigits: 1, locale: fr), "48,0")
        XCTAssertEqual(Fmt.number(1234.6, fractionDigits: 0, locale: en), "1,235")
    }

    func test_englishRegionOnFrenchMac_isNotFrenchFormatted() {
        // Locale.current is en_FR for an English UI on a French-region Mac, and prints "10,9".
        XCTAssertEqual(Fmt.number(10.94, fractionDigits: 1, locale: Locale(identifier: "en_FR")), "10,9")
        XCTAssertEqual(Fmt.number(10.94, fractionDigits: 1, locale: Fmt.language("en_FR")), "10.9")
        XCTAssertEqual(Fmt.number(10.94, fractionDigits: 1, locale: Fmt.language("fr")), "10,9")
    }

    func test_gb_endsWithUnitAndUsesAppLocaleByDefault() {
        let text = Fmt.gb(10.94)
        XCTAssertTrue(text.hasPrefix(Fmt.number(10.94, fractionDigits: 1)), text)
        XCTAssertTrue(text.hasSuffix(" GB") || text.hasSuffix(" Go"), text)
    }
}
