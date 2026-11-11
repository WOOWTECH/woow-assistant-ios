import Foundation

public enum BrowserSearchError: Error, Equatable {
    case invalidEngine, invalidTemplate, invalidQuery, limit, notFound
}

public struct BrowserSearchMatch: Equatable, Sendable {
    public let engineID: String
    public let engineName: String
    public let query: String
}

/// Manual browser search only. This is not a model/source-discovery capability.
public struct BrowserSearchEngine: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let template: String

    private init(id: String, name: String, template: String) {
        self.id = id; self.name = name; self.template = template
    }

    public init(name: String, template: String, id: UUID = UUID()) throws {
        self.init(id: "custom:" + id.uuidString.lowercased(),
                  name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                  template: template.trimmingCharacters(in: .whitespacesAndNewlines))
        try validateCustom()
    }

    public static let builtins: [BrowserSearchEngine] = [
        .init(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s"),
        .init(id: "google", name: "Google", template: "https://www.google.com/search?q=%s"),
        .init(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        .init(id: "baidu", name: "Baidu", template: "https://www.baidu.com/s?wd=%s")
    ]

    func validateCustom() throws {
        guard id.hasPrefix("custom:"), let uuid = UUID(uuidString: String(id.dropFirst(7))),
              id == "custom:" + uuid.uuidString.lowercased(),
              !name.isEmpty, name.count <= 80, Self.cleanText(name),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw BrowserSearchError.invalidEngine }
        try validateTemplate()
    }

    private func validateTemplate() throws {
        let pieces = template.components(separatedBy: "%s")
        guard pieces.count == 2, template.utf8.count <= 2048,
              template.hasPrefix("https://"), !template.contains("#"),
              !template.contains(where: { $0.isWhitespace }), Self.cleanText(template),
              Self.validEscapes(pieces[0]), Self.validEscapes(pieces[1]),
              let separator = pieces[0].range(of: "://"),
              pieces[0][separator.upperBound...].contains(where: { "/?".contains($0) }) else {
            throw BrowserSearchError.invalidTemplate
        }
        // Query placeholders belong in a value, never a parameter name.
        if let query = pieces[0].firstIndex(of: "?") {
            let lastParameter = pieces[0][pieces[0].index(after: query)...].split(separator: "&", omittingEmptySubsequences: false).last ?? ""
            guard lastParameter.contains("=") else { throw BrowserSearchError.invalidTemplate }
        }
        let sample = template.replacingOccurrences(of: "%s", with: "woowSearchProbe")
        guard let url = BrowserManualNavigationPolicy.resolve(address: sample),
              BrowserManualNavigationPolicy.libraryURL(url) == url else { throw BrowserSearchError.invalidTemplate }
    }

    public func searchURL(query: String) throws -> URL {
        try validateTemplate()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 2048, Self.cleanText(clean),
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw BrowserSearchError.invalidQuery
        }
        let address = template.replacingOccurrences(of: "%s", with: encoded)
        guard let url = BrowserManualNavigationPolicy.resolve(address: address),
              BrowserManualNavigationPolicy.libraryURL(url) == url,
              // A path-template query must not become a dot-segment traversal.
              url.standardized.path == url.path else { throw BrowserSearchError.invalidQuery }
        return url
    }

    /// Mika prefix/suffix matching and form-style decoding, exactly once.
    public func query(in url: URL) -> String? {
        guard (try? validateTemplate()) != nil, BrowserManualNavigationPolicy.allows(url) else { return nil }
        let pieces = template.components(separatedBy: "%s"), value = url.absoluteString
        guard value.hasPrefix(pieces[0]) else { return nil }
        let rest = String(value.dropFirst(pieces[0].count)), suffix = pieces[1]
        let raw: String
        if suffix.isEmpty {
            raw = String(rest.prefix { $0 != "&" && $0 != "#" })
        } else {
            var search = rest.startIndex
            var end: String.Index?
            while search < rest.endIndex, let found = rest.range(of: suffix, range: search..<rest.endIndex) {
                if found.upperBound == rest.endIndex || "&#".contains(rest[found.upperBound]) {
                    end = found.lowerBound; break
                }
                search = rest.index(after: found.lowerBound)
            }
            guard let end else { return nil }
            raw = String(rest[..<end])
        }
        guard Self.validEscapes(raw), let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
        let query = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2048, Self.cleanText(query) else { return nil }
        return query
    }

    static func cleanText(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func hex(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) }
        var i = 0
        while i < bytes.count {
            if bytes[i] == 37 {
                guard i + 2 < bytes.count, hex(bytes[i + 1]), hex(bytes[i + 2]) else { return false }
                i += 3
            } else { i += 1 }
        }
        return true
    }
}

public struct BrowserSearchSettings: Codable, Equatable, Sendable {
    public static let maximumCustomEngines = 20
    public private(set) var selectedID = "bing"
    public private(set) var custom: [BrowserSearchEngine] = []
    public init() {}
    public var all: [BrowserSearchEngine] { BrowserSearchEngine.builtins + custom }
    public var selected: BrowserSearchEngine { all.first { $0.id == selectedID } ?? BrowserSearchEngine.builtins[0] }

    public func validate() throws {
        guard custom.count <= Self.maximumCustomEngines, Set(custom.map(\.id)).count == custom.count,
              all.contains(where: { $0.id == selectedID }) else { throw BrowserSearchError.invalidEngine }
        for engine in custom { try engine.validateCustom() }
    }
    public mutating func select(_ id: String) throws {
        guard all.contains(where: { $0.id == id }) else { throw BrowserSearchError.notFound }
        selectedID = id
    }
    public mutating func add(_ engine: BrowserSearchEngine) throws {
        try engine.validateCustom()
        guard !custom.contains(where: { $0.id == engine.id }) else { return }
        guard custom.count < Self.maximumCustomEngines else { throw BrowserSearchError.limit }
        custom.append(engine); selectedID = engine.id
    }
    public mutating func remove(_ id: String) {
        guard custom.contains(where: { $0.id == id }) else { return }
        custom.removeAll { $0.id == id }
        if selectedID == id { selectedID = "bing" }
    }
    public func match(_ url: URL) -> BrowserSearchMatch? {
        guard (try? validate()) != nil else { return nil }
        for engine in all {
            if let query = engine.query(in: url) { return .init(engineID: engine.id, engineName: engine.name, query: query) }
        }
        return nil
    }
}

public enum BrowserAddressInput {
    /// URL-looking input is checked as a destination, never retried as search
    /// after a URL-policy rejection. Plain words use the selected manual engine.
    public static func resolve(_ input: String, settings: BrowserSearchSettings) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? settings.validate()) != nil, !text.isEmpty, text.utf8.count <= 8192,
              BrowserSearchEngine.cleanText(text) else { return nil }
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
            return BrowserManualNavigationPolicy.resolve(address: text)
        }
        // Recognized URL schemes remain destinations even when their slash
        // syntax is malformed. Never send their original contents to search.
        // Search operators such as site: are deliberately not URL schemes here.
        if text.hasPrefix("//") || text.range(of: "^(?i:http|https|javascript|data|file|about|blob|tel|mailto|ftp|intent):", options: .regularExpression) != nil { return nil }
        if !text.contains(where: { $0.isWhitespace }) {
            let authority = String(text.prefix { !"/?#".contains($0) })
            // Mika searches an email address, but a credential-shaped authority
            // must not leak into a remote search query.
            if authority.contains("@"), authority.contains(":") { return nil }
            let host = authority.hasPrefix("[") ? authority : String(authority.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
            let domain = "^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+(?:[A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59})$"
            let numeric = host.range(of: "^[0-9]+(?:\\.[0-9]+)+$", options: .regularExpression) != nil
            let local = ["localhost", "local", "home.arpa"].contains { host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0) }
            if host.hasPrefix("[") || numeric || local || host.range(of: domain, options: .regularExpression) != nil {
                return BrowserManualNavigationPolicy.resolve(address: "https://" + text)
            }
        }
        return try? settings.selected.searchURL(query: text)
    }
}
