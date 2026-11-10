import Foundation

public enum BrowserManualSiteMode: String, Codable, Equatable, Sendable {
    case mobile, desktop
}

/// Manual browser preferences only. Mika UserSiteModes semantics: desktop is
/// opt-in; www is ignored; children inherit; choosing mobile removes matching
/// ancestors, but leaves independently saved siblings/children intact.
public struct BrowserUserSiteModes: Codable, Equatable, Sendable {
    public static let maximumHosts = 500
    public private(set) var desktopHosts: [String] = []

    public init() {}

    public func mode(for host: String?) -> BrowserManualSiteMode {
        guard let host, let key = Self.key(host) else { return .mobile }
        return desktopHosts.contains { key == $0 || key.hasSuffix("." + $0) } ? .desktop : .mobile
    }

    public mutating func set(_ mode: BrowserManualSiteMode, for host: String) throws {
        guard let key = Self.key(host) else { throw BrowserLibraryError.invalidURL }
        if mode == .desktop {
            guard !desktopHosts.contains(key) else { return }
            guard desktopHosts.count < Self.maximumHosts else { throw BrowserLibraryError.invalidState }
            desktopHosts.append(key)
            desktopHosts.sort()
        } else {
            desktopHosts.removeAll { key == $0 || key.hasSuffix("." + $0) }
        }
    }

    public func validate() throws {
        guard desktopHosts.count <= Self.maximumHosts,
              Set(desktopHosts).count == desktopHosts.count,
              desktopHosts.allSatisfy({ Self.key($0) == $0 }) else { throw BrowserLibraryError.invalidState }
    }

    public static func key(_ host: String) -> String? {
        var key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix(".") { key.removeLast() }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        // Foundation versions differ on whether URL.host includes IPv6 brackets.
        if key.hasPrefix("["), key.hasSuffix("]") { key = String(key.dropFirst().dropLast()) }
        let authority = key.contains(":") ? "[" + key + "]" : key
        // Store a hostname, never an address, path, port, token or credential.
        // Reuse the existing public-HTTPS policy; this setting grants no URL access.
        guard !key.isEmpty, key.utf8.count <= 253,
              let parts = URLComponents(string: "https://" + authority),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              let url = parts.url, url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == key,
              BrowserManualNavigationPolicy.allows(url) else { return nil }
        return key
    }
}
