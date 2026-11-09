import Foundation
import CryptoKit

public enum SkillFrontMatterValue: Codable, Equatable, Sendable {
    case string(String)
    case list([String])

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    public var strings: [String] {
        switch self { case .string(let value): return [value]; case .list(let values): return values }
    }
}

/// Mika-compatible *subset* of YAML: scalars, quoted scalars and inline lists.
/// Not a YAML execution engine. Local metadata is not an authorization source.
public struct SkillDocument: Codable, Equatable, Sendable {
    public static let maxUTF16Count = 4000
    public let markdown: String
    public let frontMatter: [String: SkillFrontMatterValue]
    public let body: String
    public let referencedToolNames: Set<String>
    public var name: String { frontMatter["name"]?.stringValue ?? "" }
    public var description: String { frontMatter["description"]?.stringValue ?? "" }
    public var fingerprint: String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var version: String { String(fingerprint.prefix(12)) }

    /// Deliberate additive iOS localization: original Mika headings remain valid;
    /// Traditional Chinese and English equivalents are accepted as well.
    public static let sectionAliases: [[String]] = [
        ["入口", "Entry"], ["步骤", "步驟", "Steps"],
        ["容易出错的地方", "容易出錯的地方", "Pitfalls"],
        ["怎样算办成", "怎樣算辦成", "Success criteria"],
        ["什么时候停下交给用户", "什麼時候停下交給使用者", "什麼時候停下交給用戶", "When to stop"]
    ]

    public static func parse(_ markdown: String, availableToolNames: Set<String>) throws -> SkillDocument {
        try parse(markdown, availableToolNames: availableToolNames, trustedProvenance: nil)
    }

    /// Only runtime-generated or already-stored provenance may use this path.
    /// Public/import/model parsing continues to scan all raw text unchanged.
    static func parse(_ markdown: String, availableToolNames: Set<String>, trustedProvenance: UUID?) throws -> SkillDocument {
        let normalized = normalize(markdown)
        guard normalized.utf16.count <= maxUTF16Count else { throw SkillsError.tooLong }
        let (fields, body) = try parseFrontMatter(normalized)
        guard let name = fields["name"]?.stringValue,
              matches("^[a-z0-9]+(?:-[a-z0-9]+)*$", name) else { throw SkillsError.invalidName }
        guard let description = fields["description"]?.stringValue,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillsError.missingDescription
        }
        let headings = body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() }
        guard sectionAliases.allSatisfy({ aliases in
            aliases.contains { alias in headings.contains { $0.hasPrefix(alias.lowercased()) } }
        }) else { throw SkillsError.missingSection }
        let references = toolReferences(normalized)
        guard references.isSubset(of: availableToolNames) else { throw SkillsError.unknownTool }
        var privacyText = normalized
        if let trustedProvenance {
            // Exempt exactly one canonical metadata line, not all UUID-shaped
            // text. Duplicates, extra values, body text and other fields still
            // cannot hide credentials behind a supposedly trusted provenance.
            let lines = normalized.components(separatedBy: "\n")
            guard let end = closingDelimiter(lines), fields["source"]?.stringValue == "learned",
                  fields["learned_from"] == .string(trustedProvenance.uuidString) else { throw SkillsError.invalidState }
            let indices = lines.indices.filter { index in
                guard index > 0, index < end, let colon = lines[index].firstIndex(of: ":") else { return false }
                return lines[index][..<colon].trimmingCharacters(in: .whitespaces) == "learned_from"
            }
            guard indices.count == 1, let index = indices.first,
                  lines[index] == "learned_from: \(trustedProvenance.uuidString)" else { throw SkillsError.invalidState }
            var filtered = lines; filtered[index] = "learned_from: <local-run-id>"
            privacyText = filtered.joined(separator: "\n")
        }
        guard !SkillSensitiveContent.containsSensitiveValue(privacyText) else { throw SkillsError.sensitiveContent }
        return SkillDocument(markdown: normalized, frontMatter: fields, body: body, referencedToolNames: references)
    }

    private init(markdown: String, frontMatter: [String: SkillFrontMatterValue], body: String,
                 referencedToolNames: Set<String>) {
        self.markdown = markdown; self.frontMatter = frontMatter; self.body = body
        self.referencedToolNames = referencedToolNames
    }

    private enum CodingKeys: String, CodingKey { case markdown }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(markdown, forKey: .markdown)
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let markdown = try container.decode(String.self, forKey: .markdown)
        // Capabilities are runtime state, not persisted grants. Decode the document
        // structurally, then revalidate against actual tools on approval/context use.
        guard markdown.utf16.count <= Self.maxUTF16Count else { throw SkillsError.tooLong }
        // Codable restores the encrypted local snapshot, not a Markdown import.
        // This validates provenance syntax; it grants no source/approval authority.
        let (fields, _) = try Self.parseFrontMatter(Self.normalize(markdown))
        if fields["source"]?.stringValue == "learned", fields["learned_from"] != nil,
           Self.localProvenance(fields) == nil { throw SkillsError.invalidState }
        self = try Self.parse(markdown, availableToolNames: Self.toolReferences(markdown),
                              trustedProvenance: Self.localProvenance(fields))
    }

    var localProvenance: UUID? { Self.localProvenance(frontMatter) }

    private static func localProvenance(_ fields: [String: SkillFrontMatterValue]) -> UUID? {
        guard fields["source"]?.stringValue == "learned",
              let value = fields["learned_from"]?.stringValue else { return nil }
        return UUID(uuidString: value)
    }

    /// Revalidate an existing local document when capabilities change, without
    /// interpreting a trusted run identifier as user payment/identity data.
    func validated(availableToolNames: Set<String>) throws -> SkillDocument {
        try Self.parse(markdown, availableToolNames: availableToolNames, trustedProvenance: localProvenance)
    }

    static func normalize(_ value: String) -> String {
        var value = value.replacingOccurrences(of: "\r\n", with: "\n")
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        return value
    }

    static func importText(_ raw: String, source: SkillSource) throws -> String {
        guard raw.utf16.count <= maxUTF16Count * 2 else { throw SkillsError.tooLong }
        var text = normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            guard let firstNewline = text.firstIndex(of: "\n"), text.hasSuffix("```") else {
                throw SkillsError.invalidFrontMatter
            }
            text = String(text[text.index(after: firstNewline)...].dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try replacingLocalFields(text, source: source.rawValue)
    }

    static func shareable(_ markdown: String) throws -> String {
        try replacingLocalFields(markdown, source: nil)
    }

    static func replacingField(_ markdown: String, key: String, value: String) throws -> String {
        let lines = normalize(markdown).components(separatedBy: "\n")
        guard lines.first == "---", let end = closingDelimiter(lines) else { throw SkillsError.invalidFrontMatter }
        var output = ["---"]
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == key { continue }
            output.append(line)
        }
        output.append("\(key): \(value)")
        output.append(contentsOf: lines[end...])
        return output.joined(separator: "\n")
    }

    private static func replacingLocalFields(_ markdown: String, source: String?) throws -> String {
        let lines = normalize(markdown).components(separatedBy: "\n")
        guard lines.first == "---", let end = closingDelimiter(lines) else { throw SkillsError.invalidFrontMatter }
        let local: Set<String> = ["updates", "learned_from", "source"]
        var result = ["---"]
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"),
               local.contains(line[..<colon].trimmingCharacters(in: .whitespaces)) { continue }
            result.append(line)
        }
        if let source { result.append("source: \(source)") }
        result.append(contentsOf: lines[end...])
        return result.joined(separator: "\n")
    }

    private static func closingDelimiter(_ lines: [String]) -> Int? {
        lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }
    }

    private static func parseFrontMatter(_ text: String) throws -> ([String: SkillFrontMatterValue], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = closingDelimiter(lines) else { throw SkillsError.invalidFrontMatter }
        var fields: [String: SkillFrontMatterValue] = [:]
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { throw SkillsError.invalidFrontMatter }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard matches("^[a-zA-Z_][a-zA-Z0-9_-]*$", key) else { throw SkillsError.invalidFrontMatter }
            // Like Mika, the final duplicate field wins. All local duplicates are
            // stripped on import/export, so an earlier source field cannot survive.
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { throw SkillsError.invalidFrontMatter }
                fields[key] = .list(try splitList(String(raw.dropFirst().dropLast())))
            } else {
                guard !["|", ">", "|-", ">-", "|+", ">+"].contains(raw), !raw.hasPrefix("{") else {
                    throw SkillsError.invalidFrontMatter
                }
                fields[key] = .string(try unquote(raw))
            }
        }
        return (fields, lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func splitList(_ text: String) throws -> [String] {
        var result: [String] = []; var value = ""; var quote: Character?
        for char in text {
            if let current = quote {
                value.append(char)
                if char == current { quote = nil }
            } else if char == "\"" || char == "'" { quote = char; value.append(char) }
            else if char == "," { result.append(try unquote(value)); value = "" }
            else { value.append(char) }
        }
        guard quote == nil else { throw SkillsError.invalidFrontMatter }
        result.append(try unquote(value))
        return result.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            guard text.count >= 2, text.first == text.last else { throw SkillsError.invalidFrontMatter }
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    static func toolReferences(_ text: String) -> Set<String> {
        Set(captures("`([a-z][a-z0-9_]*)`", text, group: 1))
    }
    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func captures(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }
}
