import XCTest
import AssistantBrowser

final class BrowserNavigationIntentTests: XCTestCase {
    private let file = URL(string: "https://example.org/report.pdf")!
    private let redirected = URL(string: "https://cdn.example.org/report.pdf")!
    private let now = Date(timeIntervalSince1970: 100)

    func testDownloadRequiresManualInitiationAndSingleUsePermit() {
        var intent = BrowserNavigationIntent()
        let action = NSObject()
        XCTAssertFalse(intent.authorizeDownload(file, source: .action(action), now: now))
        intent.recordManualRedirect(file)
        XCTAssertFalse(intent.authorizeDownload(file, source: .action(action), now: now))
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        XCTAssertTrue(intent.consumeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
    }

    func testCancelledOrSupersededNavigationCannotDownload() {
        var intent = BrowserNavigationIntent()
        let action = NSObject()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        intent.invalidate()
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.authorizeDownload(file, source: .action(action), now: now))
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        intent.beginManual(redirected)
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.authorizeDownload(file, source: .action(action), now: now))
    }

    func testRedirectMustBelongToManualNavigationAndRemainPublicHTTPS() {
        var intent = BrowserNavigationIntent()
        let response = NSObject()
        intent.beginManual(file)
        intent.recordManualRedirect(redirected)
        XCTAssertTrue(intent.authorizeDownload(redirected, source: .response(response), now: now))
        XCTAssertTrue(intent.consumeDownload(redirected, source: .response(response), now: now))
        for value in ["http://example.org/report.pdf", "https://127.0.0.1/file", "https://user:password@example.org/file"] {
            let unsafe = URL(string: value)!
            intent.recordManualRedirect(unsafe)
            XCTAssertFalse(intent.authorizeDownload(unsafe, source: .response(response), now: now))
            intent.beginManual(unsafe)
            XCTAssertFalse(intent.authorizeDownload(unsafe, source: .response(response), now: now))
        }
    }

    func testMatchingIssuerWithExpiredOrMismatchedURLConsumesPermitWithoutAcceptingDownload() {
        var intent = BrowserNavigationIntent()
        let action = NSObject()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now.addingTimeInterval(30)))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(redirected, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(nil, source: .action(action), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(action), now: now))
    }

    func testSameURLLateCallbackCannotStealOrConsumeNewActionOrResponsePermit() {
        for isResponse in [false, true] {
            let source: (NSObject) -> BrowserNavigationIntent.DownloadSource = {
                isResponse ? .response($0) : .action($0)
            }
            var intent = BrowserNavigationIntent()
            let old = NSObject(), current = NSObject(), unrelated = NSObject()
            intent.beginManual(file)
            XCTAssertTrue(intent.authorizeDownload(file, source: source(old), now: now))
            intent.invalidate()
            intent.beginManual(file)
            XCTAssertTrue(intent.authorizeDownload(file, source: source(current), now: now))
            XCTAssertFalse(intent.consumeDownload(file, source: source(old), now: now))
            XCTAssertFalse(intent.consumeDownload(nil, source: source(unrelated), now: now))
            XCTAssertFalse(intent.consumeDownload(redirected, source: source(old), now: now))
            XCTAssertTrue(intent.consumeDownload(file, source: source(current), now: now))
            XCTAssertFalse(intent.consumeDownload(file, source: source(current), now: now))
        }
    }

    func testReplacedPolicyObjectInSameGenerationCannotConsumeNewPermit() {
        var intent = BrowserNavigationIntent()
        let old = NSObject(), current = NSObject()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .response(old), now: now))
        XCTAssertTrue(intent.authorizeDownload(file, source: .response(current), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .response(old), now: now))
        XCTAssertTrue(intent.consumeDownload(file, source: .response(current), now: now))
    }

    func testActionAndResponseKindsCannotConsumeEachOthersPermit() {
        var intent = BrowserNavigationIntent()
        let object = NSObject()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, source: .action(object), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .response(object), now: now))
        XCTAssertTrue(intent.consumeDownload(file, source: .action(object), now: now))
        XCTAssertTrue(intent.authorizeDownload(file, source: .response(object), now: now))
        XCTAssertFalse(intent.consumeDownload(file, source: .action(object), now: now))
        XCTAssertTrue(intent.consumeDownload(file, source: .response(object), now: now))
    }

    func testPermitRetainsIssuerUntilInvalidatedOrConsumedToPreventAddressReuse() {
        var intent = BrowserNavigationIntent()
        weak var issuer: NSObject?
        intent.beginManual(file)
        do {
            let object = NSObject()
            issuer = object
            XCTAssertTrue(intent.authorizeDownload(file, source: .action(object), now: now))
        }
        XCTAssertNotNil(issuer)
        intent.invalidate()
        XCTAssertNil(issuer)
        intent.beginManual(file)
        do {
            let object = NSObject()
            issuer = object
            XCTAssertTrue(intent.authorizeDownload(file, source: .response(object), now: now))
        }
        XCTAssertNotNil(issuer)
        if let object = issuer {
            XCTAssertTrue(intent.consumeDownload(file, source: .response(object), now: now))
        } else { XCTFail("Permit released its issuer before the callback") }
        XCTAssertNil(issuer)
    }
}
