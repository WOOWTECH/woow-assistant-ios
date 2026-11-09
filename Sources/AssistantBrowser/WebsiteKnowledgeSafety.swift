import CryptoKit
import Foundation

/// Deliberately fixed messages: never includes a source URL, page text or credential.
public enum WebsiteLearningError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL, sensitiveContent, invalidEvidence, invalidText, capacityExceeded
    case notFound, staleRevision, ineligibleTask, originMismatch, intentMismatch, disabledRoute, invalidState

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "This website URL cannot be retained safely."
        case .sensitiveContent: return "Potentially sensitive content cannot be retained."
        case .invalidEvidence: return "Page evidence is missing or inconsistent."
        case .invalidText: return "The text is empty or exceeds the supported limit."
        case .capacityExceeded: return "The website learning storage limit has been reached."
        case .notFound: return "The saved item no longer exists."
        case .staleRevision: return "The saved state has changed. Review the current version first."
        case .ineligibleTask: return "A confirmed successful task is required."
        case .originMismatch: return "The website origin does not match."
        case .intentMismatch: return "The requested intent does not match this route."
        case .disabledRoute: return "This route is disabled after repeated mismatches."
        case .invalidState: return "The website learning data is invalid."
        }
    }
}

/// An exact scheme/host/effective-port scope, never a suffix/domain-wide grant.
/// BrowserPolicy is a URL filter, not a DNS or authenticated-content safety proof.
public struct WebsiteOrigin: Codable, Equatable, Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        let safe = try WebsiteLearningSafety.publicURL(url)
        guard var parts = URLComponents(url: safe, resolvingAgainstBaseURL: false) else {
            throw WebsiteLearningError.invalidURL
        }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let origin = parts.url else { throw WebsiteLearningError.invalidURL }
        self.url = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(url: container.decode(URL.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url)
    }
}

enum WebsiteLearningSafety {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ values: [String]) -> String {
        // Length-prefix framing makes ambiguous field concatenations impossible.
        digest(values.map { "\($0.utf8.count):\($0)" }.joined())
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && abs(value.timeIntervalSince1970) <= 253_402_300_799
    }
    static func dateKey(_ value: Date) -> String { String(value.timeIntervalSinceReferenceDate.bitPattern) }
    static func normalized(_ value: String) -> String { value.precomposedStringWithCanonicalMapping }
    static func text(_ value: String, max: Int) throws -> String {
        let clean = normalized(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf16.count <= max else { throw WebsiteLearningError.invalidText }
        guard !clean.unicodeScalars.contains(where: {
            (CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t")
                || (0x200B...0x200F).contains($0.value) || (0x202A...0x202E).contains($0.value)
                || (0x2060...0x206F).contains($0.value)
        }) else { throw WebsiteLearningError.sensitiveContent }
        guard !sensitive(clean) else { throw WebsiteLearningError.sensitiveContent }
        return clean
    }
    /// Validate without rewriting user literals, whitespace, case or Unicode spelling.
    static func originalGoal(_ value: String) throws -> String {
        guard value.utf16.count <= 4000 else { throw WebsiteLearningError.invalidText }
        // CR/CRLF are legitimate goal line breaks. Normalize ONLY this validation
        // copy; all other control/secret checks are the same as retained text.
        _ = try text(value.replacingOccurrences(of: "\r", with: "\n"), max: 4000)
        return value
    }
    static func intent(_ value: String) throws -> String {
        let clean = normalized(try originalGoal(value))
        return clean.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Conservative known-secret exclusion, not a guarantee of detecting every secret.
    /// Callers must never supply private form fields or authenticated account contents.
    static func sensitive(_ value: String) -> Bool {
        let value = value.precomposedStringWithCompatibilityMapping
        let credentials = #"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[A-Z0-9]{16})\b|\bBearer\s+\S+|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----"#
        let labeled = #"(?:password|passwd|passcode|api[ _-]?key|access[ _-]?token|refresh[ _-]?token|client[ _-]?secret|authorization|cookie|session[ _-]?id|密碼|密码|驗證碼|验证码|安全碼|安全码)\s*(?:[:=：]|\bis\b|是|為|为)\s*\S+|\b(?:pin|otp|cvv|cvc)\s*[:=：]?\s*[0-9]{3,}"#
        let capabilityURL = #"https?://[^\s]*(?:/webhook(?:/|\b)|[?&#](?:key|token|secret|signature|api_key|access_token)=)|https?://[^\s/]+@"#
        return matches(credentials, value) || matches(labeled, value) || matches(capabilityURL, value)
    }

    /// Fail closed instead of silently stripping query credentials or hash-router state.
    /// A URL-only check cannot establish public DNS resolution or harmless GET semantics.
    static func publicURL(_ url: URL) throws -> URL {
        guard url.baseURL == nil, url.absoluteString.utf8.count <= 2048,
              case .allow = BrowserPolicy.evaluate(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              var host = parts.host?.lowercased(), let scheme = parts.scheme?.lowercased() else {
            throw WebsiteLearningError.invalidURL
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.contains(".") || host.contains(":"),
              ![".internal", ".lan", ".corp"].contains(where: host.hasSuffix) else {
            throw WebsiteLearningError.invalidURL
        }
        var decodedPath = parts.percentEncodedPath
        for _ in 0..<3 { decodedPath = decodedPath.removingPercentEncoding ?? decodedPath }
        guard !sensitive(url.absoluteString), !sensitive(decodedPath),
              !matches(#"(?:^|/)(?:webhook|token|tokens|secret|secrets|password|reset-password|logout|signout|delete|destroy|unsubscribe|revoke|checkout|pay|submit)(?:/|$)|[a-f0-9]{32,}|[A-Za-z0-9_\-]{64,}"#, decodedPath),
              !decodedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WebsiteLearningError.sensitiveContent
        }
        parts.scheme = scheme; parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let safe = parts.url, case .allow = BrowserPolicy.evaluate(safe) else {
            throw WebsiteLearningError.invalidURL
        }
        return safe
    }
}
