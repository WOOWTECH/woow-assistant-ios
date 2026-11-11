import Foundation
import AssistantBrowser

enum BrowserSearchChecks {
    struct Failure: Error { let check: String }
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(check: name) }; count += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }; throw Failure(check: name)
        }
        var settings = BrowserSearchSettings()
        try check(settings.selected.id == "bing" && settings.custom.isEmpty, "default Bing")
        try check(settings.all.map(\.id) == ["bing", "google", "duckduckgo", "baidu"], "Mika built-in order")
        for engine in settings.all {
            let url = try engine.searchURL(query: "  中文 a+b & c/#?%= 😀  ")
            try check(engine.query(in: url) == "中文 a+b & c/#?%= 😀", "UTF-8 single encoding round trip " + engine.id)
            try check(url.user == nil && url.password == nil && url.fragment == nil, "query cannot inject authority or fragment")
            try check(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1, "query cannot inject parameter")
        }
        for (input, wanted) in [("plain words", "plain words"), ("中文", "中文"), ("one", "one"), ("me@example.com", "me@example.com"), ("  %2520 + & #  ", "%2520 + & #"),
                                ("site:example", "site:example"), ("site:example.com tea", "site:example.com tea")] {
            let url = BrowserAddressInput.resolve(input, settings: settings)
            try check(url.flatMap(settings.match)?.query == wanted && url?.host == "www.bing.com", "manual text/email query")
        }
        for (input, wanted) in [("example.com", "https://example.com"), ("example.com:443/path?q=one", "https://example.com:443/path?q=one"),
                                ("8.8.8.8/path", "https://8.8.8.8/path"), ("[2606:4700::1111]/", "https://[2606:4700::1111]/"),
                                (" https://example.com/path?q=a#b ", "https://example.com/path?q=a#b"),
                                ("xn--bcher-kva.de", "https://xn--bcher-kva.de")] {
            try check(BrowserAddressInput.resolve(input, settings: settings) == URL(string: wanted), "URL classification: " + input)
        }
        for blocked in ["", " \n", "http://example.com", "javascript:alert(1)", "data:text/html,x", "file:///tmp/x", "//example.com",
                        "https:127.0.0.1", "http:localhost", "https:/private.invalid/path", " HTTPS:example.invalid ",
                        "https:/user:synthetic@example.invalid/", "https:example.invalid/?token=synthetic",
                        "http:", "https:", "https:///example.invalid", "http:/example.invalid",
                        "https://user:pass@example.com", "user:pass@example.com", "https://example.com:/", "example.com:",
                        "https://example.com:999999999999999999999/", "example.com:999999999999999999999/",
                        "localhost", "localhost:80/path", "printer.local", "home.arpa", "10.0.0.1", "127.1", "[::1]/",
                        "https://127.0.0.1", "https://[fe80::1]", "https://user@example.com", "words\u{0000}here", String(repeating: "x", count: 8193)] {
            try check(BrowserAddressInput.resolve(blocked, settings: settings) == nil, "URL rejection never searches: " + String(blocked.prefix(80)))
        }
        let bing = settings.selected
        try check(bing.query(in: URL(string: "https://www.bing.com/search?q=a+b%2520&extra=1#part")!) == "a b%20", "plus and percent decode once")
        try check(bing.query(in: URL(string: "https://www.bing.com/search?q=%E4%B8%AD%E6%96%87")!) == "中文", "external UTF-8 query restored")
        for wrong in ["https://www.bing.com.evil.invalid/search?q=a", "https://evil.invalid/?next=https://www.bing.com/search?q=a", "https://www.bing.com/search?other=1&q=a", "https://www.bing.com/search?q=", "https://www.bing.com/search?q=%FF"] {
            try check(bing.query(in: URL(string: wrong)!) == nil, "no misleading search match")
        }
        for query in ["", "  ", "a\u{0000}b", String(repeating: "中", count: 683)] {
            try rejects("query bound/control rejection") { _ = try bing.searchURL(query: query) }
        }
        let custom = try BrowserSearchEngine(name: "  Local fixture  ", template: " https://research.example.invalid/search?q=%s&lang=en \n")
        try check(custom.name == "Local fixture", "custom trims input")
        let customURL = try custom.searchURL(query: "&lang=en evil%20 +/javascript:alert(1)")
        try check(custom.query(in: customURL) == "&lang=en evil%20 +/javascript:alert(1)", "suffix cannot be injected by query")
        try check(custom.query(in: URL(string: customURL.absoluteString + "&extra=1#part")!) != nil, "suffix allows trailing parameter and fragment")
        try check(custom.query(in: URL(string: "https://research.example.invalid/search?q=one&lang=en-evil")!) == nil, "suffix boundary")
        let pathEngine = try BrowserSearchEngine(name: "Path", template: "https://search.example.invalid/search/%s/results")
        let pathURL = try pathEngine.searchURL(query: "a/b?x=y#javascript:alert(1)")
        try check(pathEngine.query(in: pathURL) == "a/b?x=y#javascript:alert(1)", "path-template escaped query")
        try check(pathURL.host == "search.example.invalid" && pathURL.query == nil && pathURL.fragment == nil, "path query cannot inject navigation syntax")
        try rejects("dot traversal path query") { _ = try pathEngine.searchURL(query: "..") }
        for template in ["http://example.com/?q=%s", "javascript:alert('%s')", "file:///tmp/%s", "https://localhost/?q=%s",
                         "https://127.0.0.1/?q=%s", "https://10.0.0.1/%s", "https://[::1]/%s", "https://%s.example.com/",
                         "https://example.%s/", "https://user:pass@example.com/?q=%s", "https://user@example.com/?q=%s",
                         "https://example.com:/?q=%s", "https://example.com:999999999999999999999/?q=%s",
                         "https://example.com/?q=none", "https://example.com/?q=%s%s", "https://example.com/?q=%25s",
                         "https://example.com/?q=%s&token=synthetic", "https://example.com/?access_token=%s",
                         "https://example.com/oauth/%s", "https://example.com/#%s", "https://example.com/?q=%s#fixed",
                         "https://example.com/?%s=value", "https://example.com/?q=%s&broken=%GG", "https://example.com/?q=%s x",
                         "https://example.com/" + String(repeating: "x", count: 2048) + "%s"] {
            try rejects("reject unsafe/invalid template") { _ = try BrowserSearchEngine(name: "Fixture", template: template) }
        }
        for name in ["", "   ", "a\u{0000}b", String(repeating: "a", count: 81)] {
            try rejects("invalid display name") { _ = try BrowserSearchEngine(name: name, template: "https://example.com/?q=%s") }
        }
        try settings.select("google")
        try check(BrowserAddressInput.resolve("words", settings: settings)?.host == "www.google.com", "selected engine used")
        try settings.add(custom)
        try check(settings.selected == custom && settings.all.last == custom, "add selects custom after builtins")
        try settings.add(custom)
        try check(settings.custom.count == 1, "duplicate ID does not add another engine")
        let copy = settings
        try rejects("unknown selection") { try settings.select("missing") }
        try check(settings == copy, "failed selection atomic")
        settings.remove("bing")
        try check(settings == copy, "builtins cannot be removed")
        settings.remove(custom.id)
        try check(settings.selectedID == "bing" && settings.custom.isEmpty, "remove selected custom falls back to Bing")
        for i in 0..<BrowserSearchSettings.maximumCustomEngines {
            try settings.add(BrowserSearchEngine(name: "Engine \(i)", template: "https://example.com/?q=%s"))
        }
        let full = settings
        try rejects("custom bound") { try settings.add(custom) }
        try check(settings == full, "capacity failure atomic")
        var library = BrowserLibraryState()
        try library.addSearchEngine(custom)
        try library.setManualSiteMode(.desktop, for: "example.com")
        try library.visit(tab: library.selectedID, url: customURL, title: "Search results")
        try library.bookmark(url: customURL, title: "Saved search")
        try library.validate()
        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(BrowserLibraryState.self, from: data)
        try restored.validate()
        try check(restored == library, "full library round trip")
        try check(restored.searchSettings.match(restored.history[0].url)?.query == custom.query(in: customURL), "query restored from saved URL, not second search")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "searchSettings")
        let old = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate()
        try check(old.searchSettings == BrowserSearchSettings(), "absent additive field defaults Bing")
        try check(old.tabs == library.tabs && old.bookmarks == library.bookmarks && old.history == library.history
                  && old.userSiteModes == library.userSiteModes && old.selectedID == library.selectedID, "legacy migration preserves prior browser state")
        let malformedFields: [Any] = [NSNull(), "bing", ["selectedID": "missing", "custom": [Any]()] as [String: Any],
            ["selectedID": "bing", "custom": [["id": "bing", "name": "Fake", "template": "https://example.com/?q=%s"]]] as [String: Any]]
        for malformed in malformedFields {
            var bad = legacy; bad["searchSettings"] = malformed
            try rejects("malformed present field fails closed") {
                let value = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: bad))
                try value.validate()
            }
        }
        library.clearHistory()
        try check(library.searchSettings.selected == custom && library.history.isEmpty && library.bookmarks.count == 1, "clear history retains engine and bookmark")
        return count
    }
}
