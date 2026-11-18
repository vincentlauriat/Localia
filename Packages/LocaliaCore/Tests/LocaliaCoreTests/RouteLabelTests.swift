import XCTest
@testable import LocaliaCore

final class RouteLabelTests: XCTestCase {
    /// The stored reasons read as short labels; the normal route and anything unknown show nothing.
    func test_routeLabel_mapsReasons() {
        XCTAssertEqual(RouteLabel.text(routedTo: "llamacpp", reason: "engine-down"), "Fallback — engine stopped")
        XCTAssertEqual(RouteLabel.text(routedTo: "ollama", reason: "pinned"), "Fixed engine")
        XCTAssertNil(RouteLabel.text(routedTo: "ollama", reason: "primary"))
        XCTAssertNil(RouteLabel.text(routedTo: nil, reason: nil), "a row the router did not route")
        XCTAssertNil(RouteLabel.text(routedTo: "ollama", reason: "some-future-reason"), "never a raw value")
    }
}
