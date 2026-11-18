import XCTest
@testable import LocaliaCore

final class JSONNumbersTests: XCTestCase {
    private func json(_ s: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(#"{"v": \#(s)}"#.utf8)) as? [String: Any])?["v"]
    }

    func test_positiveInt() {
        XCTAssertEqual(JSONNumbers.positiveInt(json("40960")), 40960)
        XCTAssertEqual(JSONNumbers.positiveInt(json("1")), 1)
        XCTAssertEqual(JSONNumbers.positiveInt(json("2.9")), 2, "truncated")
        XCTAssertEqual(JSONNumbers.positiveInt(json("2147483647")), Int(Int32.max))
        for bad in ["0", "0.5", "-1", "2147483648", "1e308", "true", "\"40960\"", "null", "[1]"] {
            XCTAssertNil(JSONNumbers.positiveInt(json(bad)), bad)
        }
        XCTAssertNil(JSONNumbers.positiveInt(nil))
        XCTAssertNil(JSONNumbers.positiveInt(Double.nan))
        XCTAssertNil(JSONNumbers.positiveInt(Double.infinity))
    }

    func test_nonNegativeInt() {
        XCTAssertEqual(JSONNumbers.nonNegativeInt(json("0")), 0)
        XCTAssertEqual(JSONNumbers.nonNegativeInt(json("0.5")), 0)
        XCTAssertEqual(JSONNumbers.nonNegativeInt(json("17")), 17)
        XCTAssertEqual(JSONNumbers.nonNegativeInt(json("2147483647")), Int(Int32.max))
        for bad in ["-1", "-0.5", "2147483648", "1e308", "false", "\"3\"", "null", "{}"] {
            XCTAssertNil(JSONNumbers.nonNegativeInt(json(bad)), bad)
        }
        XCTAssertNil(JSONNumbers.nonNegativeInt(nil))
        XCTAssertNil(JSONNumbers.nonNegativeInt(Double.nan))
    }
}
