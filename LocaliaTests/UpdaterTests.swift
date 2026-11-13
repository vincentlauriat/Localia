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

    func test_checkIsDisabledWhileACheckRuns_orWhenUnavailable() {
        XCTAssertTrue(Updater.canCheckNow(isAvailable: true, canCheckForUpdates: true))
        XCTAssertFalse(Updater.canCheckNow(isAvailable: true, canCheckForUpdates: false), "check in progress")
        XCTAssertFalse(Updater.canCheckNow(isAvailable: false, canCheckForUpdates: true))
        XCTAssertFalse(Updater(enabled: false).canCheckNow)
    }
}
