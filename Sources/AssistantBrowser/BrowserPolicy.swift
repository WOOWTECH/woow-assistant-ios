import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct BrowserTab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var url: URL?
    public var lastVisitedAt: Date

    public init(id: UUID = UUID(), title: String = "New Tab", url: URL? = nil, lastVisitedAt: Date = .now) {
        self.id = id
        self.title = title
        self.url = url
        self.lastVisitedAt = lastVisitedAt
    }
}

public enum BrowserURLDecision: Sendable, Equatable {
    case allow(URL)
    case block(reason: String)
}

public enum BrowserPolicy {
    /// Validate the original address as well as Foundation's parsed destination.
    /// Some iOS 17 Foundation versions silently discard empty/overflowing ports.
    /// Callers receiving text must not lose that evidence by constructing URL first.
    public static func evaluate(address: String) -> BrowserURLDecision {
        guard let url = URL(string: address) else { return .block(reason: Denial.authority) }
        // Preserve Foundation's existing IDNA host handling. The original
        // authority syntax/port is checked here; the parsed host is checked below.
        let raw = evaluate(url, address: address, validateHost: false)
        if case .block = raw { return raw }
        return evaluate(url)
    }

    /// A URL-only navigation policy for the URL Foundation has already parsed.
    /// This does not resolve DNS: an allowed name may resolve to a private address,
    /// change through DNS rebinding, or lead to private redirects/subresources.
    /// It is not a DNS/SSRF boundary. A gateway must separately validate resolved
    /// destinations at connection time and every redirect, and enforce egress rules.
    public static func evaluate(_ url: URL) -> BrowserURLDecision {
        evaluate(url, address: url.absoluteURL.absoluteString)
    }

    private static func evaluate(_ url: URL, address: String, validateHost: Bool = true) -> BrowserURLDecision {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return .block(reason: Denial.scheme)
        }

        // Inspect the serialized authority as well as the scheme. Foundation and
        // browsers differ on legacy numeric hosts, escaped hosts and malformed ports.
        // Do not inspect the path/query for '@', IP addresses or escaped characters.
        guard let separator = address.range(of: "://"),
              address[..<separator.lowerBound].lowercased() == scheme else {
            return .block(reason: Denial.missingHost)
        }
        let authority = address[separator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.isEmpty else { return .block(reason: Denial.missingHost) }
        guard !authority.contains("@") else { return .block(reason: Denial.credentials) }

        let host: String
        let port: Substring?
        let isIPv6 = authority.first == "["
        if isIPv6 {
            guard let closingBracket = authority.firstIndex(of: "]") else {
                return .block(reason: Denial.ipv6)
            }
            host = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            let suffix = authority[authority.index(after: closingBracket)...]
            guard suffix.isEmpty || suffix.first == ":" else {
                return .block(reason: Denial.authority)
            }
            port = suffix.isEmpty ? nil : suffix.dropFirst()
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return .block(reason: Denial.authority) }
            host = String(parts[0])
            port = parts.count == 2 ? parts[1] : nil
        }

        guard !host.isEmpty else { return .block(reason: Denial.missingHost) }
        if let port = port {
            guard isDecimal(port), let number = Int(port), (1...65535).contains(number) else {
                return .block(reason: Denial.port)
            }
        }

        guard validateHost else { return .allow(url) }

        if isIPv6 {
            guard !host.contains("%") else { return .block(reason: Denial.ipv6Zone) }
            guard let bytes = ipv6Bytes(host) else { return .block(reason: Denial.ipv6) }
            if let reason = ipv6Denial(bytes) { return .block(reason: reason) }
        } else {
            guard !host.contains("%") else { return .block(reason: Denial.encodedHost) }
            // A single DNS root dot is valid, including after an IPv4 literal.
            // Two dots still produce an empty label and are rejected below.
            let name = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
            guard isDNSName(name) else { return .block(reason: Denial.host) }
            if isLocalName(name) { return .block(reason: Denial.localName) }

            if let bytes = ipv4Bytes(name) {
                if let reason = ipv4Denial(bytes) { return .block(reason: reason) }
            } else if endsInNumber(name) {
                // Browser URL parsing can interpret a numeric last label as IPv4.
                // Reject shorthand, integer, octal, hex and overflowing forms;
                // never mistake e.g. 172.2.example.com for an IP address.
                return .block(reason: Denial.numericHost)
            }
        }
        return .allow(url)
    }

    private enum Denial {
        static let scheme = "Only HTTP and HTTPS pages can open in the assistant browser."
        static let missingHost = "A web address needs a host name."
        static let credentials = "Web addresses containing user information or credentials are not allowed."
        static let authority = "The web address has a malformed authority."
        static let port = "A web address port must be a decimal number between 1 and 65535."
        static let host = "The web address has an invalid host name."
        static let encodedHost = "Percent-encoded host names are not supported; use a plain host name or IDNA ASCII name."
        static let numericHost = "IPv4 addresses must use four decimal octets without leading zeros; other numeric host forms are not supported."
        static let ipv6 = "The host must be a valid IPv6 address enclosed in brackets."
        static let ipv6Zone = "IPv6 zone identifiers are not supported."
        static let ipv4Compatible = "Deprecated IPv4-compatible IPv6 addresses are not supported."
        static let localName = "Local-only host names are disabled in the first release."
        static let privateAddress = "Private-network addresses are disabled in the first release."
        static let loopback = "Loopback addresses are disabled in the first release."
        static let linkLocal = "Link-local addresses are disabled in the first release."
        static let unspecified = "Unspecified addresses are not browsing destinations."
        static let shared = "Shared-address-space destinations are disabled in the first release."
        static let multicast = "Multicast addresses are not browsing destinations."
        static let reserved = "Reserved IPv4 addresses are not browsing destinations."
    }

    private static func isDecimal<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isDNSName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func isLocalName(_ name: String) -> Bool {
        ["localhost", "local", "home.arpa"].contains { name == $0 || name.hasSuffix("." + $0) }
    }

    private static func endsInNumber(_ name: String) -> Bool {
        guard let label = name.split(separator: ".").last else { return false }
        if isDecimal(label) { return true }
        return label.hasPrefix("0x") && label.dropFirst(2).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes = [UInt8]()
        for part in parts {
            guard isDecimal(part), part.count == 1 || part.first != "0",
                  let byte = UInt8(part) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        // Darwin inet_pton accepts leading zeros in an embedded dotted IPv4
        // address. Apply our canonical IPv4 syntax before parsing the IPv6 bytes.
        if host.contains(".") {
            guard let dottedSuffix = host.split(separator: ":").last,
                  ipv4Bytes(String(dottedSuffix)) != nil else { return nil }
        }
        var address = in6_addr()
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv4Denial(_ bytes: [UInt8]) -> String? {
        let first = bytes[0], second = bytes[1]
        if bytes.allSatisfy({ $0 == 0 }) { return Denial.unspecified }
        if first == 127 { return Denial.loopback }
        if first == 10 || (first == 172 && (16...31).contains(second)) ||
            (first == 192 && second == 168) { return Denial.privateAddress }
        if first == 169 && second == 254 { return Denial.linkLocal }
        if first == 100 && (64...127).contains(second) { return Denial.shared }
        if (224...239).contains(first) { return Denial.multicast }
        if first == 0 || first >= 240 { return Denial.reserved }
        return nil
    }

    private static func ipv6Denial(_ bytes: [UInt8]) -> String? {
        if bytes.allSatisfy({ $0 == 0 }) { return Denial.unspecified }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return Denial.loopback }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            // Both ::ffff:192.168.1.1 and ::ffff:c0a8:101 use the IPv4 rules.
            return ipv4Denial(Array(bytes.suffix(4)))
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return Denial.ipv4Compatible }
        if bytes[0] & 0xfe == 0xfc { return Denial.privateAddress }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return Denial.linkLocal }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return Denial.privateAddress }
        if bytes[0] == 0xff { return Denial.multicast }
        return nil
    }
}
