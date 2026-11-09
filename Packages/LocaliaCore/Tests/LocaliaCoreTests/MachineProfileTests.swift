import XCTest
@testable import LocaliaCore

final class MachineProfileTests: XCTestCase {
    func test_usablePool_appleSilicon_usesWorkingSetMinusHeadroom() {
        let p = MachineProfile(chip: "Apple M5", totalRAMGB: 24, gpuWorkingSetGB: 17.76, isAppleSilicon: true)
        XCTAssertEqual(p.usablePoolGB, 16.26, accuracy: 0.001)
    }

    func test_usablePool_neverNegative() {
        let p = MachineProfile(chip: "Apple M5", totalRAMGB: 24, gpuWorkingSetGB: 1.0, isAppleSilicon: true)
        XCTAssertEqual(p.usablePoolGB, 0)
    }

    func test_current_onThisMac_isPlausible() {
        let p = MachineProfile.current()
        print("MachineProfile.current(): \(p)")
        XCTAssertGreaterThan(p.gpuWorkingSetGB, 0)
        XCTAssertLessThanOrEqual(p.gpuWorkingSetGB, p.totalRAMGB)
    }
}
