import XCTest
@testable import AssistantBrowser

final class BrowserLibraryTests: XCTestCase {
    func testManualAddressRejectsMalformedPortsWithoutChangingTheDestination() {
        for authority in ["example.com:", "example.com:999999999999999999999999", "example.com:0", "example.com:65536", "[2606:4700::1111]:", "[2606:4700::1111]:999999999999999999999999"] {
            XCTAssertNil(BrowserManualNavigationPolicy.resolve(address: "https://\(authority)/"))
        }
        for address in ["https://example.com/path?next=host:999999999999999999999999#part", "https://example.com:443/", "https://example.com:00080/", "https://[2606:4700::1111]:65535/"] {
            XCTAssertEqual(BrowserManualNavigationPolicy.resolve(address: address), URL(string: address))
        }
        // Modern Foundation converts these hosts to IDNA; older parsers can
        // reject them. Raw port validation must preserve existing host handling.
        for address in ["https://bücher.de/", "https://例子.tw/"] {
            if let parsed = URL(string: address) {
                XCTAssertEqual(BrowserManualNavigationPolicy.resolve(address: address), parsed)
            } else {
                XCTAssertNil(BrowserManualNavigationPolicy.resolve(address: address))
            }
        }
    }

    func testManualNavigationDoesNotRelaxResearchPolicy() throws {
        for address in ["https://example.com/login?return=%2Faccount", "https://example.com/#section", "https://example.com/checkout"] {
            let url = URL(string: address)!
            XCTAssertTrue(BrowserManualNavigationPolicy.allows(url))
        }
        for address in ["http://example.com", "https://user:pass@example.com", "https://127.0.0.1", "https://10.0.0.1", "file:///tmp/a", "javascript:alert(1)"] {
            XCTAssertFalse(BrowserManualNavigationPolicy.allows(URL(string: address)!))
        }
        XCTAssertThrowsError(try WebsiteOrigin(url: URL(string: "https://example.com/?q=search")!))
        XCTAssertThrowsError(try WebsiteOrigin(url: URL(string: "https://example.com/checkout")!))
    }

    func testTabsSelectionClosingAndRestore() throws {
        var state = BrowserLibraryState()
        let first = state.selectedID
        let second = try state.addTab(url: URL(string: "https://example.com/second")!)
        try state.select(first)
        try state.close(second)
        XCTAssertEqual(state.selectedID, first)
        try state.close(first)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertNotEqual(state.selectedID, first)
        for _ in 1..<BrowserLibraryState.maximumTabs { _ = try state.addTab() }
        XCTAssertThrowsError(try state.addTab())
        let restored = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONEncoder().encode(state))
        try restored.validate()
        XCTAssertEqual(restored, state)
    }

    func testBookmarksDeduplicateFragmentsAndPreserveUserTitles() throws {
        var state = BrowserLibraryState()
        let url = URL(string: "https://example.com/page?q=one#first")!
        try state.bookmark(url: url, title: "Original")
        let id = try XCTUnwrap(state.bookmarks.first?.id)
        try state.renameBookmark(id, title: "My title")
        try state.visit(tab: state.selectedID, url: URL(string: "https://example.com/page?q=one#second")!, title: "Website title")
        XCTAssertEqual(state.bookmarks.first?.title, "My title")
        XCTAssertEqual(state.history.first?.url.absoluteString, "https://example.com/page?q=one")
        XCTAssertThrowsError(try state.renameBookmark(id, title: "  "))
        try state.bookmark(url: URL(string: "https://example.com/page?q=one#third")!, title: "Re-added")
        XCTAssertEqual(state.bookmarks.count, 1)
        state.removeBookmark(state.bookmarks[0].id)
        XCTAssertTrue(state.bookmarks.isEmpty)
    }

    func testHistoryCapacityOrderAndSeparateClear() throws {
        var state = BrowserLibraryState()
        let bookmarked = URL(string: "https://example.com/bookmark")!
        try state.bookmark(url: bookmarked, title: "Keep")
        for i in 0..<520 {
            try state.visit(tab: state.selectedID, url: URL(string: "https://example.com/\(i)")!, title: "Page \(i)")
        }
        XCTAssertEqual(state.history.count, 500)
        XCTAssertEqual(state.history.first?.title, "Page 519")
        try state.visit(tab: state.selectedID, url: state.history[10].url, title: "Revisit")
        XCTAssertEqual(state.history.count, 500)
        XCTAssertEqual(state.history.first?.title, "Revisit")
        state.clearHistory()
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.bookmarks.count, 1)
        XCTAssertNotNil(state.tabs.first?.url)
        try state.validate()
    }

    func testCallbackSecretsNotRetainedOrBookmarked() throws {
        var state = BrowserLibraryState()
        let safe = URL(string: "https://example.com/home")!
        try state.visit(tab: state.selectedID, url: safe, title: "Home")
        for address in ["https://example.com/?code=secret", "https://example.com/?access_token=secret", "https://example.com/?apiKey=secret", "https://example.com/?accessToken=secret", "https://example.com/?clientSecret=secret", "https://example.com/webhook/secret", "https://example.com/oauth/callback"] {
            let url = URL(string: address)!
            XCTAssertTrue(BrowserManualNavigationPolicy.allows(url))
            XCTAssertNil(BrowserManualNavigationPolicy.libraryURL(url))
            XCTAssertThrowsError(try state.bookmark(url: url, title: "No"))
            try state.visit(tab: state.selectedID, url: url, title: "Private")
            XCTAssertNil(state.tabs.first?.url)
            XCTAssertEqual(state.tabs.first?.title, "網站登入頁面")
            XCTAssertEqual(state.history.count, 1)
        }
        let bytes = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
        try state.validate()
    }

    func testCorruptLibraryIsRejectedInsteadOfReset() throws {
        let state = BrowserLibraryState()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["version"] = 999
        let decoded = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try decoded.validate())
        json["version"] = 1; json["tabs"] = [Any]()
        let empty = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try empty.validate())
    }
}
