import XCTest
@testable import Localia

@MainActor
final class UpdaterTests: XCTestCase {
    func test_emptyOrMissingPublicKey_doesNotStartUpdater() {
        XCTAssertFalse(Updater.hasPublicKey(nil))
        XCTAssertFalse(Updater.hasPublicKey([:]))
        XCTAssertFalse(Updater.hasPublicKey(["SUPublicEDKey": ""]))
        XCTAssertFalse(Updater.hasPublicKey(["SUPublicEDKey": "  \n"]))
        XCTAssertFalse(Updater(info: ["SUPublicEDKey": ""]).isAvailable)
    }

    func test_publicKeyPresent_isRecognised() {
        XCTAssertTrue(Updater.hasPublicKey(["SUPublicEDKey": "abc="]))
    }

    func test_disabled_neverStartsEvenWithKey() {
        XCTAssertFalse(Updater(info: ["SUPublicEDKey": "abc="], enabled: false).isAvailable)
    }
}
