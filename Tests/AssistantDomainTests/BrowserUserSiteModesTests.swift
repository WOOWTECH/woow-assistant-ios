import XCTest

final class BrowserUserSiteModesTests: XCTestCase {
    func testNormalizationInheritanceBoundsAndLegacySchema() throws {
        XCTAssertGreaterThan(try BrowserUserSiteModesChecks.run(), 40)
    }
}
