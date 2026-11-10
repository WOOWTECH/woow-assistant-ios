import Foundation

// Reference: Mika 0c172724f3f0c96f7345262588072f6e95db1138,
// general/ProfileEdit.kt and memory/UserUtterances.kt, NumberText.kt.
public enum UserProfileToolOperation: String, Sendable { case add, replace, delete }

public enum UserProfileToolError: String, Error, LocalizedError, Equatable, Sendable {
    case invalidArguments = "invalid_arguments"
    case quoteNotFromUser = "quote_not_from_user"
    case contentNotFromUser = "content_not_from_user"
    case staleRevision = "stale_revision"

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Use only valid op, text, match and quote arguments."
        case .quoteNotFromUser: return "The quote must be actual user words from this run."
        case .contentNotFromUser: return "Concrete profile details must come from this run's user words."
        case .staleRevision: return "The profile changed after this proposal was prepared."
        }
    }
}

/// Parse only an explicitly selected tool's argument object, never ordinary
/// assistant prose. Parsing/quote membership is not authorization to apply it.
public struct UserProfileToolRequest: Sendable {
    public let op: UserProfileToolOperation
    public let text: String?
    public let match: String?
    public let quote: String

    private init(op: UserProfileToolOperation, text: String?, match: String?, quote: String) {
        self.op = op; self.text = text; self.match = match; self.quote = quote
    }

    public static func parse(_ argumentsJSON: String) throws -> Self {
        var parser = ProfileArgumentParser(argumentsJSON)
        let fields = try parser.parse()
        guard let rawOp = fields["op"], let op = UserProfileToolOperation(rawValue: rawOp),
              let quote = fields["quote"], validArgument(quote, maximum: 1000) else {
            throw UserProfileToolError.invalidArguments
        }
        for key in ["text", "match"] {
            if let value = fields[key], !validArgument(value, maximum: 160) {
                throw UserProfileToolError.invalidArguments
            }
        }
        guard (op == .delete || fields["text"] != nil),
              (op == .add || fields["match"] != nil) else {
            throw UserProfileToolError.invalidArguments
        }
        return Self(op: op, text: fields["text"], match: fields["match"], quote: quote)
    }

    /// The host supplies only this run's actual user utterances, separately from
    /// model messages, profile context, attachments, web/tool text and old turns.
    /// There is no previous-confirmation exception for profile_edit. The outer
    /// App must separately obtain explicit proposal approval and gate useMemory.
    public func prepare(state: UserProfileState, utterances: [String]) throws -> UserProfileToolReview {
        let normalizedQuote = ProfileToolGrounding.normalizedQuote(quote)
        guard normalizedQuote.utf16.count >= 2,
              utterances.contains(where: {
                  ProfileToolGrounding.normalizedQuote($0).range(of: normalizedQuote, options: .literal) != nil
              }) else { throw UserProfileToolError.quoteNotFromUser }
        if let text, !ProfileToolGrounding.supported(text, quote: quote, utterances: utterances) {
            throw UserProfileToolError.contentNotFromUser
        }
        // Exercise the existing state rules on a disposable value. Entry IDs and
        // timestamps are minted again on approval; this is not a pending write.
        var candidate = state
        let entry = try change(&candidate, now: Date(timeIntervalSince1970: 0))
        let remainingIDs = Set(candidate.snapshot().entries.map(\.id))
        let before = state.snapshot().entries.first { !remainingIDs.contains($0.id) }?.text
        return UserProfileToolReview(request: self, baseRevision: state.revision,
                                     before: before, after: entry?.text)
    }

    fileprivate func change(_ state: inout UserProfileState, now: Date) throws -> UserProfileEntry? {
        switch op {
        case .add: return try state.add(text: text!, now: now)
        case .replace: return try state.replace(segment: match!, replacement: text!, now: now)
        case .delete: try state.delete(segment: match!, now: now); return nil
        }
    }

    private static func validArgument(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum
    }
}

/// Immutable review data, not Codable/model-constructible. Approval is a host UI
/// action: apply to a copy, persist the complete encrypted snapshot atomically,
/// then publish the value and receipt. Do not emit a receipt before persistence.
public struct UserProfileToolReview: Identifiable, Sendable {
    public let id: UUID
    public let baseRevision: UUID
    public let op: UserProfileToolOperation
    public let quote: String
    public let before: String?
    public let after: String?
    private let request: UserProfileToolRequest

    fileprivate init(request: UserProfileToolRequest, baseRevision: UUID, before: String?, after: String?) {
        id = UUID(); self.baseRevision = baseRevision; self.request = request
        op = request.op; quote = request.quote; self.before = before; self.after = after
    }

    public func apply(to state: inout UserProfileState, now: Date) throws -> UserProfileToolReceipt {
        guard state.revision == baseRevision else { throw UserProfileToolError.staleRevision }
        var next = state
        let entry = try request.change(&next, now: now)
        state = next
        return UserProfileToolReceipt(id: entry?.id)
    }
}

public struct UserProfileToolReceipt: Encodable, Sendable {
    public let applied: Bool
    public let id: UUID?
    public let effective: String

    fileprivate init(id: UUID?) { applied = true; self.id = id; effective = "next_run" }
}

/// This tool has a flat string/null object. Parse that exact grammar so duplicate
/// keys (including escaped spellings), trailing text and non-string values cannot
/// be silently accepted by a dictionary decoder. Optional null matches Args.str.
private struct ProfileArgumentParser {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func parse() throws -> [String: String] {
        var values: [String: String] = [:], seen = Set<String>()
        try require(0x7B)
        if !take(0x7D) {
            while true {
                let key = try string()
                guard ["op", "text", "match", "quote"].contains(key), seen.insert(key).inserted else {
                    throw UserProfileToolError.invalidArguments
                }
                try require(0x3A)
                whitespace()
                if bytes.dropFirst(offset).starts(with: [0x6E, 0x75, 0x6C, 0x6C]) {
                    offset += 4
                } else { values[key] = try string() }
                if take(0x7D) { break }
                try require(0x2C)
            }
        }
        whitespace()
        guard offset == bytes.count else { throw UserProfileToolError.invalidArguments }
        return values
    }

    private mutating func string() throws -> String {
        whitespace()
        let start = offset
        guard take(0x22) else { throw UserProfileToolError.invalidArguments }
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 0x22 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw UserProfileToolError.invalidArguments }
            }
            if byte == 0x5C {
                guard offset < bytes.count else { throw UserProfileToolError.invalidArguments }
                offset += 1
            }
        }
        throw UserProfileToolError.invalidArguments
    }

    private mutating func whitespace() {
        while offset < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
    private mutating func require(_ byte: UInt8) throws {
        guard take(byte) else { throw UserProfileToolError.invalidArguments }
    }
}

private enum ProfileToolGrounding {
    static func normalizedQuote(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func supported(_ text: String, quote: String, utterances: [String]) -> Bool {
        let content = comparable(text), sources = (utterances + [quote]).map(comparable)
        // Preserve the pinned heuristic, including its limitations for unquoted
        // Chinese names/places. Do not add the shared MemorySafety grammar list.
        let specifics = captures(#"[「『“"]([^「」『』“”"\n]+)[」』”"]"#, content, group: 1)
            + captures(#"[0-9]+"#, content)
            + captures(#"[A-Za-z][A-Za-z0-9._-]{2,}"#, content)
            + captures(#"\p{Han}{2}(?:小区|大厦|广场|公寓|花园|单元|路|街|巷|弄|镇|村|号|楼|栋|室|区|县|市|省|园|苑|城|道|里|湾)"#, content)
        return specifics.allSatisfy { value in
            let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return needle.isEmpty || sources.contains {
                $0.range(of: needle, options: [.literal, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
            }
        }
    }

    private static func comparable(_ value: String) -> String {
        let normalized = value.precomposedStringWithCompatibilityMapping
        let digits: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "三": "3",
                                               "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
        let chinese = replacing(#"[零〇一二三四五六七八九十百千]{3,}"#, normalized) { run in
            let converted = String(run.compactMap { digits[$0] })
            return converted.isEmpty ? run : converted
        }
        let joined = replacing(#"[0-9](?:[\s\-.,]*[0-9])+"#, chinese) { run in
            let converted = run.filter { $0 >= "0" && $0 <= "9" }
            return converted.utf16.count >= 3 ? converted : run
        }
        return replacing("用户的|用户|我的|我", joined) { _ in "" }
    }

    private static func captures(_ pattern: String, _ value: String, group: Int = 0) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let text = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: text.length)).map {
            text.substring(with: $0.range(at: group))
        }
    }

    private static func replacing(_ pattern: String, _ value: String, transform: (String) -> String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern), text = value as NSString
        let result = NSMutableString(string: value)
        for match in expression.matches(in: value, range: NSRange(location: 0, length: text.length)).reversed() {
            result.replaceCharacters(in: match.range, with: transform(text.substring(with: match.range)))
        }
        return result as String
    }
}
