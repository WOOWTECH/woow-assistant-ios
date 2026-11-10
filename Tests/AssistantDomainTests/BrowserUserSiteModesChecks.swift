import Foundation
import AssistantBrowser

enum BrowserUserSiteModesChecks {
    struct Failure: Error { let check: String }
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(check: name) }; count += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }; throw Failure(check: name)
        }
        var modes = BrowserUserSiteModes()
        try check(modes.mode(for: nil) == .mobile, "nil defaults mobile")
        try check(modes.mode(for: "example.com") == .mobile, "manual default mobile")
        try modes.set(.desktop, for: " WWW.Example.COM... \n")
        try check(modes.desktopHosts == ["example.com"], "Mika normalization")
        for host in ["example.com", "www.example.com", "m.example.com", "deep.shop.example.com"] {
            try check(modes.mode(for: host) == .desktop, "inherit " + host)
        }
        for host in ["example.org", "notexample.com", "example.com.evil.org"] {
            try check(modes.mode(for: host) == .mobile, "label boundary " + host)
        }
        for host in ["8.8.8.8", "[2606:4700::1111]", "xn--bcher-kva.de"] {
            var addressModes = BrowserUserSiteModes()
            try addressModes.set(.desktop, for: host)
            try check(addressModes.mode(for: host) == .desktop, "public IP/IDNA hostname " + host)
        }
        try modes.set(.desktop, for: "shop.example.com")
        try modes.set(.desktop, for: "child.m.example.com")
        try modes.set(.mobile, for: "m.example.com")
        try check(modes.mode(for: "example.com") == .mobile, "mobile removes ancestor")
        try check(modes.mode(for: "m.example.com") == .mobile, "mobile child")
        try check(modes.mode(for: "shop.example.com") == .desktop, "independent sibling retained")
        try check(modes.mode(for: "child.m.example.com") == .desktop, "independent child retained")
        for host in ["", " ", "https://example.com", "user:pass@example.com", "example.com/path", "example.com?token=x",
                     "example.com#fragment", "example.com:443", "127.0.0.1", "localhost", "exa mple.com", "example.com\n.evil.org"] {
            let before = modes
            try rejects("invalid hostname") { try modes.set(.desktop, for: host) }
            try check(modes == before, "invalid choice atomic")
        }
        var bounded = BrowserUserSiteModes()
        for i in 0..<BrowserUserSiteModes.maximumHosts { try bounded.set(.desktop, for: "h\(i).example.com") }
        try bounded.set(.desktop, for: "h0.example.com")
        try rejects("bounded hostname set") { try bounded.set(.desktop, for: "overflow.example.com") }
        try bounded.validate()
        var library = BrowserLibraryState()
        let url = URL(string: "https://example.com/page")!
        try library.visit(tab: library.selectedID, url: url, title: "Fixture")
        try library.bookmark(url: url, title: "Saved")
        try library.setManualSiteMode(.desktop, for: "example.com")
        let bytes = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(BrowserLibraryState.self, from: bytes)
        try restored.validate()
        try check(restored == library, "round trip all metadata")
        var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        legacy.removeValue(forKey: "userSiteModes")
        let migrated = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try migrated.validate()
        try check(migrated.userSiteModes.mode(for: "example.com") == .mobile, "old vault defaults mobile")
        try check(migrated.tabs == library.tabs && migrated.history == library.history && migrated.bookmarks == library.bookmarks
                  && migrated.selectedID == library.selectedID, "migration preserves browser data")
        for invalid: Any in [NSNull(), "desktop", ["desktopHosts": ["example.com/path"]],
                             ["desktopHosts": ["example.com", "example.com"]], ["desktopHosts": ["WWW.example.com"]]] {
            var malformed = legacy; malformed["userSiteModes"] = invalid
            try rejects("malformed new field fail closed") {
                let decoded = try JSONDecoder().decode(BrowserLibraryState.self, from: JSONSerialization.data(withJSONObject: malformed))
                try decoded.validate()
            }
        }
        library.clearHistory()
        try check(library.userSiteModes.mode(for: "example.com") == .desktop && library.bookmarks.count == 1,
                  "history clear keeps preference and bookmark")
        count += try reloadMethodEvidence()
        return count
    }

    /// Shared by the ordinary hosted XCTest and the local standalone runner.
    /// Method-state evidence only; does not claim native HTTP execution.
    static func reloadMethodEvidence() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw Failure(check: name) }; count += 1
        }
        let url = URL(string: "https://example.com/page")!
        let navigation = NSObject(), other = NSObject()
        var reload = BrowserSiteModeReloadState()
        try check(!reload.allowsReload(navigation: navigation, url: url), "unknown document cannot reload")
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true, expectedNavigation: navigation)
        reload.start(navigation)
        try check(!reload.allowsReload(navigation: navigation, url: url), "start is not a finished document")
        reload.commit(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "commit must finish")
        reload.finish(navigation, url: url)
        try check(reload.allowsReload(navigation: navigation, url: url), "actual GET bound to finished navigation")
        try check(!reload.allowsReload(navigation: other, url: url), "same URL different document cannot reuse GET")
        try check(!reload.allowsReload(navigation: navigation, url: URL(string: "https://example.com/changed")!), "changed URL cannot reuse GET")
        reload.observePolicy(url: url, method: "POST", hasBody: true, manual: true, allowed: true)
        reload.start(other); reload.commit(other, url: url); reload.finish(other, url: url)
        reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: other, url: url), "POST at same URL cannot inherit old GET or late finish")
        for method: String? in [nil, "POST", "HEAD", "PUT"] {
            reload.invalidate()
            reload.observePolicy(url: url, method: method, hasBody: false, manual: true, allowed: true)
            reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
            try check(!reload.allowsReload(navigation: navigation, url: url), "non-GET method cannot reload")
        }
        for (body, manual, allowed) in [(true, true, true), (false, false, true), (false, true, false)] {
            reload.invalidate()
            reload.observePolicy(url: url, method: "GET", hasBody: body, manual: manual, allowed: allowed)
            reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
            try check(!reload.allowsReload(navigation: navigation, url: url), "body/automation/denied GET cannot reload")
        }
        reload.invalidate()
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true, expectedNavigation: other)
        reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "explicit navigation identity mismatch")
        reload.invalidate()
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true)
        reload.start(navigation); reload.redirect(navigation)
        reload.commit(navigation, url: url); reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "redirect without final method cannot reload")
        reload.invalidate()
        reload.observePolicy(url: url, method: "POST", hasBody: true, manual: true, allowed: true)
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true)
        reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "overlapping policies are ambiguous")
        reload.invalidate()
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true)
        reload.start(navigation)
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true)
        reload.start(other); reload.commit(other, url: url); reload.finish(other, url: url)
        try check(!reload.allowsReload(navigation: other, url: url), "in-flight overlap cannot bless replacement")
        reload.invalidate()
        reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "missing policy evidence stays unknown")
        reload.invalidate()
        reload.observePolicy(url: url, method: "GET", hasBody: false, manual: true, allowed: true)
        reload.start(navigation); reload.commit(navigation, url: url); reload.finish(navigation, url: url)
        reload.invalidate(); reload.finish(navigation, url: url)
        try check(!reload.allowsReload(navigation: navigation, url: url), "cancellation cannot be undone by late finish")
        return count
    }
}
