import XCTest

final class BrowserSearchTests: XCTestCase {
    func testManualAddressEncodingEnginesAndLegacyLibrary() throws {
        XCTAssertGreaterThan(try BrowserSearchChecks.run(), 90)
    }
}
