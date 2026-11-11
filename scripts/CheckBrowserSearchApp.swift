import Foundation
import WebKit
import AssistantBrowser
import AssistantPersistence
#if os(iOS)
import UIKit
#if canImport(XCTest)
@testable import WoowAssistant
#endif
#else
import AppKit
#endif

private final class BrowserSearchKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var unavailable = false
    func read(id: String) throws -> Data? {
        if unavailable { throw LearningFileError.unavailable }; return values[id]
    }
    func insert(_ key: Data, id: String) throws {
        if unavailable { throw LearningFileError.unavailable }; values[id] = key
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

@MainActor enum BrowserSearchAppChecks {
    struct Failure: Error { let check: String }
    static func run() async throws -> [String: Any] {
        var count = try BrowserSearchChecks.run()
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(check: name) }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-browser-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.vault"), keys = BrowserSearchKeys()
        func vault() -> EncryptedLearningFile { EncryptedLearningFile(url: file, keys: keys) }
        let languageSuite = "woow-language-search-" + UUID().uuidString
        let languageDefaults = UserDefaults(suiteName: languageSuite)!
        defer { languageDefaults.removePersistentDomain(forName: languageSuite) }
        let language = AppLanguageStore(defaults: languageDefaults, preferredLanguages: { ["zh-TW"] })
        let store = WKWebsiteDataStore.nonPersistent()
        let workspace = BrowserWorkspace(dataStore: store, vault: vault(), downloadDirectory: root.appendingPathComponent("Downloads"))
        let browser = workspace.selected, probe = BrowserSiteModesAppChecks.Probe(workspace.selected)
        let host = try BrowserSiteModesAppChecks.Host()
        defer { workspace.cancelAllWork(); host.close() }
        host.attach(browser); browser.webView.navigationDelegate = probe
        try check(workspace.available && workspace.library.searchSettings.selectedID == "bing", "actual workspace defaults Bing")
        browser.address = " \n "; browser.openAddress()
        try check(browser.error == nil && probe.actions.isEmpty, "empty input is a no-op")

        // Exercise openAddress and the real policy delegate; the probe cancels
        // the outgoing request before network I/O. No search service is contacted.
        browser.address = "first query & #/+% 中文"
        browser.openAddress()
        try await BrowserSiteModesAppChecks.wait("actual Bing navigation action", { probe.actions.count == 1 && !browser.webView.isLoading })
        try check(probe.actions[0].host == "www.bing.com" && probe.actions[0].method == "GET" && probe.actions[0].policy == .allow,
                  "actual App resolves words through default engine")
        try check(workspace.selectSearchEngine("google"), "select built-in persists")
        browser.address = "second query"
        browser.openAddress()
        try await BrowserSiteModesAppChecks.wait("actual Google navigation action", { probe.actions.count == 2 && !browser.webView.isLoading })
        try check(probe.actions[1].host == "www.google.com" && probe.actions[1].method == "GET", "selected engine wired to same session")
        let beforeInvalid = probe.actions.count
        for invalid in ["https://127.0.0.1/", "https://example.com:/", "http://example.com/", "javascript:alert(1)", "https://user:pass@example.com/",
                        "https:127.0.0.1", "http:localhost", "https:/private.invalid/path", "HTTPS:example.invalid",
                        "https:/user:synthetic@example.invalid/", "https:example.invalid/?token=synthetic"] {
            browser.address = invalid; browser.openAddress()
            try check(browser.error != nil, "rejected input reports an error without a search")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(probe.actions.count == beforeInvalid, "blocked URL not reinterpreted as remote search")

        try check(workspace.addSearchEngine(name: "Fixture Search", template: "https://research.example.invalid/search?q=%s&lang=en"), "add custom through actual workspace")
        let engine = workspace.library.searchSettings.selected
        let query = "fixture cats & dogs/+% 中文"
        let url = try engine.searchURL(query: query)
        let html = "<!doctype html><title>Search fixture</title><p>LOCAL SEARCH FIXTURE</p><input aria-label='Search note' value='retained'>"
        func load(_ target: URL) async throws {
            let finishes = probe.finishes
            probe.localHTMLURL = target
            var request = URLRequest(url: target); request.httpMethod = "GET"
            browser.manualNavigation(to: target) { browser.webView.loadSimulatedRequest(request, responseHTML: html) }
            try await BrowserSiteModesAppChecks.wait("completed local search document", { probe.finishes == finishes + 1 && browser.loadedURL == target && !browser.webView.isLoading })
        }
        try await load(url)
        try check(browser.manualSearchMatch?.query == query && browser.manualSearchMatch?.engineName == "Fixture Search", "query restored in actual App")
        try check(browser.address == url.absoluteString, "address retains destination URL")
        try check(browser.current == nil && !browser.automationOwnsDocument, "query page remains manual and outside readonly research")
        try check(workspace.library.history.count == 1 && workspace.library.history[0].url == url, "history persists actual result URL")
        workspace.addBookmark()
        try check(workspace.library.bookmarks.first?.url == url, "saved search reopens its original URL")
        let cookie = HTTPCookie(properties: [.domain: "research.example.invalid", .path: "/", .name: "search_fixture", .value: "synthetic"])!
        await store.httpCookieStore.setCookie(cookie)
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('input').value='keep document'; true")
        let originalView = browser.webView, originalNavigation = probe.lastNavigation
        let actions = probe.actions.count, finishes = probe.finishes
        let beforeLanguage = workspace.library
        let draftBeforeLanguage = browser.address
        try check(language.setFromUser(.english) && language.setFromUser(.simplifiedChinese), "change display language with a live manual document")
        try check(workspace.library == beforeLanguage && workspace.selected === browser && browser.address == draftBeforeLanguage,
                  "language preserves encrypted metadata, session and address draft")
        try check(workspace.selectSearchEngine("bing"), "change engine on completed document")
        try await Task.sleep(nanoseconds: 100_000_000)
        let note = try await browser.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        let cookies = await store.httpCookieStore.allCookies()
        try check(probe.actions.count == actions && probe.finishes == finishes && probe.lastNavigation === originalNavigation,
                  "engine change never navigates/reloads/repeats document")
        try check(browser.webView === originalView && note == "keep document" && cookies.contains { $0.name == cookie.name && $0.value == cookie.value },
                  "same view, fields and cookie survive selection")
        try check(browser.manualSearchMatch?.query == query, "query recognition uses all engines, not only selected")
        try check(workspace.selectSearchEngine(engine.id), "restore custom selection")
        let ciphertext = try Data(contentsOf: file)
        try check(!String(decoding: ciphertext, as: UTF8.self).contains("Fixture Search")
                  && !String(decoding: ciphertext, as: UTF8.self).contains("research.example.invalid"), "engine template and search history encrypted")
        let reopened = BrowserWorkspace(dataStore: store, vault: vault(), downloadDirectory: root.appendingPathComponent("Downloads"))
        defer { reopened.cancelAllWork() }
        try check(reopened.available && reopened.library == workspace.library, "encrypted restart preserves library and selected custom engine")
        try check(reopened.selected.manualSearchSettings().selected == engine && reopened.selected.address == url.absoluteString,
                  "restored session keeps original URL and new resolver")
        let beforeFailure = workspace.library
        keys.unavailable = true
        try check(!workspace.selectSearchEngine("google") && workspace.library == beforeFailure, "failed encrypted write does not publish")
        try check(try Data(contentsOf: file) == ciphertext, "failed write preserves ciphertext")
        keys.unavailable = false
        try check(!workspace.addSearchEngine(name: "Unsafe", template: "https://127.0.0.1/?q=%s") && workspace.library == beforeFailure,
                  "invalid template leaves workspace intact")
        workspace.newTab()
        try check(workspace.selected.manualSearchSettings().selected == engine, "new tabs use saved engine")
        try check(workspace.library.tabs.count == 2 && workspace.downloads.items.isEmpty, "tabs/download state preserved")
        try check(workspace.removeSearchEngine(engine.id), "delete selected custom")
        try check(workspace.library.searchSettings.selectedID == "bing" && workspace.library.history.first?.url == url
                  && workspace.library.bookmarks.first?.url == url, "delete falls back without rewriting saved result URLs")
        workspace.clearHistory()
        try check(workspace.library.history.isEmpty && workspace.library.bookmarks.count == 1
                  && workspace.library.searchSettings.selectedID == "bing", "history clear and engine state stay separate")
        // Load the actual pre-field encrypted schema, then save the additive field.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(beforeFailure)) as! [String: Any]
        legacy.removeValue(forKey: "searchSettings")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyFile = EncryptedLearningFile(url: root.appendingPathComponent("legacy.vault"), keys: keys)
        _ = try legacyFile.load(LegacyJSON.self)
        try legacyFile.save(JSONDecoder().decode(LegacyJSON.self, from: legacyData))
        let migrated = BrowserWorkspace(dataStore: .nonPersistent(), vault: legacyFile, downloadDirectory: root.appendingPathComponent("LegacyDownloads"))
        defer { migrated.cancelAllWork() }
        try check(migrated.available && migrated.library.searchSettings.selectedID == "bing", "actual encrypted legacy defaults Bing")
        try check(migrated.library.tabs == beforeFailure.tabs && migrated.library.bookmarks == beforeFailure.bookmarks
                  && migrated.library.history == beforeFailure.history && migrated.library.userSiteModes == beforeFailure.userSiteModes,
                  "encrypted migration preserves existing browser records")
        try check(migrated.selectSearchEngine("duckduckgo"), "migrated encrypted store can save new field")
        var damaged = try Data(contentsOf: file); damaged[damaged.count - 1] ^= 1; try damaged.write(to: file)
        let corrupt = BrowserWorkspace(dataStore: .nonPersistent(), vault: vault(), downloadDirectory: root.appendingPathComponent("CorruptDownloads"))
        try check(!corrupt.available && !corrupt.selectSearchEngine("google") && (try Data(contentsOf: file)) == damaged,
                  "corrupt vault unavailable and not overwritten")
        return ["assertions": count, "actual_webkit": true, "external_network_or_personal_keychain": false,
                "actual_default_and_selected_search_actions": 2, "engine_change_navigations": 0,
                "encrypted_restart_and_legacy_migration": true, "native_ui_execution": false]
    }

    private struct LegacyJSON: Codable {
        var version: Int
        var tabs: [BrowserTab]
        var selectedID: UUID
        var bookmarks: [BrowserSavedPage]
        var history: [BrowserSavedPage]
        var userSiteModes: BrowserUserSiteModes
    }
}

#if BROWSER_SEARCH_APP_STANDALONE
@main struct BrowserSearchCheckMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                var result = try await BrowserSearchAppChecks.run()
                result["existing_site_mode_regression_assertions"] = try await BrowserSiteModesAppChecks.run()["assertions"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                exit(0)
            } catch { print("FAIL \(error)"); exit(1) }
        }
        app.run()
    }
}
#endif
