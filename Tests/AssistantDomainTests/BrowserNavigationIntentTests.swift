import XCTest
import AssistantBrowser

final class BrowserNavigationIntentTests: XCTestCase {
    private let file = URL(string: "https://example.org/report.pdf")!
    private let redirected = URL(string: "https://cdn.example.org/report.pdf")!
    private let now = Date(timeIntervalSince1970: 100)

    func testDownloadRequiresManualInitiationAndSingleUsePermit() {
        var intent = BrowserNavigationIntent()
        XCTAssertFalse(intent.authorizeDownload(file, now: now))
        intent.recordManualRedirect(file)
        XCTAssertFalse(intent.authorizeDownload(file, now: now))
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        XCTAssertTrue(intent.consumeDownload(file, now: now))
        XCTAssertFalse(intent.consumeDownload(file, now: now))
    }

    func testCancelledOrSupersededNavigationCannotDownload() {
        var intent = BrowserNavigationIntent()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        intent.invalidate()
        XCTAssertFalse(intent.consumeDownload(file, now: now))
        XCTAssertFalse(intent.authorizeDownload(file, now: now))
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        intent.beginManual(redirected)
        XCTAssertFalse(intent.consumeDownload(file, now: now))
        XCTAssertFalse(intent.authorizeDownload(file, now: now))
    }

    func testRedirectMustBelongToManualNavigationAndRemainPublicHTTPS() {
        var intent = BrowserNavigationIntent()
        intent.beginManual(file)
        intent.recordManualRedirect(redirected)
        XCTAssertTrue(intent.authorizeDownload(redirected, now: now))
        XCTAssertTrue(intent.consumeDownload(redirected, now: now))
        for value in ["http://example.org/report.pdf", "https://127.0.0.1/file", "https://user:password@example.org/file"] {
            let unsafe = URL(string: value)!
            intent.recordManualRedirect(unsafe)
            XCTAssertFalse(intent.authorizeDownload(unsafe, now: now))
            intent.beginManual(unsafe)
            XCTAssertFalse(intent.authorizeDownload(unsafe, now: now))
        }
    }

    func testExpiredOrMismatchedCallbackConsumesPermitWithoutAcceptingDownload() {
        var intent = BrowserNavigationIntent()
        intent.beginManual(file)
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        XCTAssertFalse(intent.consumeDownload(file, now: now.addingTimeInterval(30)))
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        XCTAssertFalse(intent.consumeDownload(redirected, now: now))
        XCTAssertFalse(intent.consumeDownload(file, now: now))
        XCTAssertTrue(intent.authorizeDownload(file, now: now))
        XCTAssertFalse(intent.consumeDownload(nil, now: now))
        XCTAssertFalse(intent.consumeDownload(file, now: now))
    }
}
