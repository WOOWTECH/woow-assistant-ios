import Foundation

// Pinned Mika 0c172724f3f0c96f7345262588072f6e95db1138:
// general/MemoryTools.kt, memory/UserUtterances.kt, tool/Args.kt, ToolDef.kt.
public enum MemoryToolOperation: String, Sendable { case add, update, delete }

public enum MemoryToolError: String, Error, Equatable, Sendable {
    case invalidArguments = "invalid_arguments"
    case disabled = "memory_disabled"
    case quoteNotFromUser = "quote_not_from_user"
    case contentNotFromUser = "content_not_from_user"
    case editNotRequested = "edit_not_requested"
    case notFound = "not_found"
    case ambiguousTarget = "ambiguous_target"
    case staleRevision = "stale_revision"
}

/// Data only. The host selects the tool name; neither parsing nor preparing is
/// permission to write. Optional reason is display metadata, never evidence.
public struct MemoryToolRequest: Sendable {
    public let toolName: String
    public let reason: String?
    fileprivate let query: String?
    fileprivate let op: MemoryToolOperation?
    fileprivate let target: String?
    fileprivate let kind: MemoryKind?
    fileprivate let content: String?
    fileprivate let quote: String?
    fileprivate let keywords: [String]?

    public static func parse(name: String, argumentsJSON: String) throws -> Self {
        let strings: Set<String>
        let arrays: Set<String>
        switch name {
        case "memory_search": strings = ["query", "reason"]; arrays = []
        case "memory_save": strings = ["kind", "content", "quote", "reason"]; arrays = ["keywords"]
        case "memory_edit": strings = ["op", "id", "content", "quote", "reason"]; arrays = ["keywords"]
        default: throw MemoryToolError.invalidArguments
        }
        var parser = MemoryArgumentParser(argumentsJSON, strings: strings, arrays: arrays)
        let fields = try parser.parse()
        func string(_ key: String, max: Int, required: Bool = false) throws -> String? {
            guard case .string(let value)? = fields[key] else {
                if required { throw MemoryToolError.invalidArguments }; return nil
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf16.count <= max else { throw MemoryToolError.invalidArguments }
            return value
        }
        // ToolDef has an optional string reason but no reason-specific length
        // limit. The host bounds model response bytes; do not invent a 1000 cap.
        let reason: String?
        if case .string(let value)? = fields["reason"] { reason = value } else { reason = nil }
        let query = try string("query", max: 100, required: name == "memory_search")
        let content = try string("content", max: 200, required: name == "memory_save")
        let quote = try string("quote", max: 1000, required: name != "memory_search")
        let target = try string("id", max: 200, required: name == "memory_edit")
        let rawKind = try string("kind", max: Int.max, required: name == "memory_save")
        let kind = rawKind.flatMap(MemoryKind.init(rawValue:))
        if rawKind != nil && kind == nil { throw MemoryToolError.invalidArguments }
        var op: MemoryToolOperation? = name == "memory_save" ? .add : nil
        if name == "memory_edit" {
            let value = try string("op", max: Int.max, required: true)
            guard value == "update" || value == "delete" else { throw MemoryToolError.invalidArguments }
            op = value == "update" ? .update : .delete
            if op == .update && content == nil { throw MemoryToolError.invalidArguments }
        }
        let keywords: [String]?
        if case .strings(let values)? = fields["keywords"] {
            guard values.count <= 8, values.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 30
            }) else { throw MemoryToolError.invalidArguments }
            keywords = values
        } else { keywords = nil }
        return Self(toolName: name, reason: reason, query: query, op: op, target: target,
                    kind: kind, content: content, quote: quote, keywords: keywords)
    }
}

public struct MemoryToolSearchItem: Encodable, Sendable {
    public let id: UUID
    public let kind: MemoryKind
    public let content: String
    fileprivate init(_ item: MemoryItem) { id = item.id; kind = item.kind; content = item.content }
}

public struct MemoryToolSearchResult: Encodable, Sendable {
    public let ok: Bool
    public let memories: [MemoryToolSearchItem]
    fileprivate init(_ items: [MemoryItem]) { ok = true; memories = items.map(MemoryToolSearchItem.init) }
    public func resultJSON() throws -> String { try memoryToolJSON(self) }
}

/// Host-owned state for exactly one run. Capture after context markUsed. The
/// snapshot/utterances never change and candidates can only come from search.
/// The host checks its live generation/master switch/revision before EVERY call.
public struct MemoryToolRun: Sendable {
    public let baseRevision: UUID
    private let snapshot: MemoryState
    private let utterances: [String]
    private var candidates: [UUID]?

    public init(state: MemoryState, utterances: [String]) {
        snapshot = state; baseRevision = state.revision; self.utterances = utterances
    }

    public mutating func search(argumentsJSON: String) throws -> MemoryToolSearchResult {
        guard snapshot.preferences.useMemory else { throw MemoryToolError.disabled }
        let request = try MemoryToolRequest.parse(name: "memory_search", argumentsJSON: argumentsJSON)
        let found = snapshot.search(request.query!, limit: 8, includePending: false)
        candidates = found.map(\.id) // Even an empty successful search replaces the old set.
        return MemoryToolSearchResult(found)
    }

    /// Current-run user words only. The pinned save-only previous-confirmation
    /// exception is intentionally NOT offered by this first API. Website/tool/
    /// assistant text and old turns must not be passed as current utterances.
    public func prepare(toolName: String, argumentsJSON: String) throws -> MemoryToolReview {
        guard snapshot.preferences.useMemory else { throw MemoryToolError.disabled }
        let request = try MemoryToolRequest.parse(name: toolName, argumentsJSON: argumentsJSON)
        guard let op = request.op, let quote = request.quote else { throw MemoryToolError.invalidArguments }
        let normalized = MemoryToolGrounding.normalizedQuote(quote)
        let messages = utterances.map(MemoryToolGrounding.normalizedQuote).filter {
            normalized.utf16.count >= 2 && $0.range(of: normalized, options: .literal) != nil
        }
        guard !messages.isEmpty else { throw MemoryToolError.quoteNotFromUser }
        var targetID: UUID?
        if op != .add {
            let positive = op == .update ? Self.updateRequest : Self.deleteRequest
            let negative = op == .update ? Self.updateNegation : Self.deleteNegation
            guard MemorySafety.matches(positive, quote), !messages.contains(where: { MemorySafety.matches(negative, $0) }) else {
                throw MemoryToolError.editNotRequested
            }
            guard let candidates, let rawID = request.target,
                  let id = candidates.first(where: { $0.uuidString == rawID }) else { throw MemoryToolError.notFound }
            if candidates.count > 1 {
                let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: rawID) + "(?![A-Za-z0-9_-])"
                guard quote.range(of: pattern, options: .regularExpression) != nil else {
                    throw MemoryToolError.ambiguousTarget
                }
            }
            targetID = id
        }
        if op != .delete {
            guard ([request.content!] + (request.keywords ?? [])).allSatisfy({
                MemoryToolGrounding.supported($0, quote: quote, utterances: utterances)
            }) else { throw MemoryToolError.contentNotFromUser }
        }
        let sourceQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation: MemoryOperation
        switch op {
        case .add: operation = .add(request.kind!, request.content!, request.keywords ?? [], sourceQuote)
        case .update: operation = .update(targetID!, request.content!, request.keywords, sourceQuote)
        case .delete: operation = .forget(targetID!)
        }
        var candidate = snapshot
        let note = try candidate.applyToolOperation(operation, baseRevision: baseRevision,
            conversationID: nil, now: Date(timeIntervalSince1970: 0))
        let before = snapshot.memories.first { $0.id == targetID }.map(MemoryToolValue.init)
        let after = candidate.memories.first { $0.id == note.memoryID }.map(MemoryToolValue.init)
        return MemoryToolReview(baseRevision: baseRevision, toolName: toolName, op: op, targetID: targetID,
                                quote: quote, before: before, after: after, operation: operation)
    }

    // Localization extension to pinned Mika's literal Simplified Chinese/English
    // patterns: Traditional Chinese spellings and corresponding negations. The
    // negative check always uses FULL matching current messages, never only the
    // model-selected quote. These literal checks do not infer semantic consent.
    private static let updateRequest = #"修改|改成|改为|改為|更新|更正|改掉|编辑|編輯|\b(?:update|change|edit|correct)\b"#
    private static let deleteRequest = #"删除|刪除|删掉|刪掉|删了|刪了|忘掉|忘记|忘記|别记|別記|不要记|不要記|取消记忆|取消記憶|\b(?:delete|forget|remove)\b"#
    private static let updateNegation = #"(?:不|别|別|无需|無需|无须|無須|不用|不必|不要|不能|不准|禁止)\s*(?:要|用|再|去)?\s*(?:修改|改成|改为|改為|更新|更正|改掉|编辑|編輯)|\b(?:do\s+not|don't|dont|never|no\s+need\s+to)\s+(?:update|change|edit|correct)\b"#
    private static let deleteNegation = #"(?:不|别|別|无需|無需|无须|無須|不用|不必|不要|不能|不准|禁止)\s*(?:要|用|再|去)?\s*(?:删(?:除|掉|了)?|刪(?:除|掉|了)?|忘掉|忘记|忘記|取消记忆|取消記憶|别记|別記|不要记|不要記)|\b(?:do\s+not|don't|dont|never)\s+(?:delete|forget|remove)\b"#
}

/// UI preview omits provisional IDs/timestamps: these are minted on apply.
public struct MemoryToolValue: Equatable, Sendable {
    public let kind: MemoryKind
    public let content: String
    public let keywords: [String]
    public let status: MemoryStatus
    fileprivate init(_ item: MemoryItem) {
        kind = item.kind; content = item.content; keywords = item.keywords; status = item.status
    }
}

/// iOS delta: pinned tools apply immediately after validation; this core prepares
/// immutable review data and requires a separate host approval. Approval of a
/// procedure WRITE does not activate that procedure; it remains pending.
public struct MemoryToolReview: Identifiable, Sendable {
    public let id: UUID
    public let baseRevision: UUID
    public let toolName: String
    public let op: MemoryToolOperation
    public let targetID: UUID?
    public let quote: String
    public let before: MemoryToolValue?
    public let after: MemoryToolValue?
    public var kind: MemoryKind? { (after ?? before)?.kind }
    /// Effective replacement keywords; nil for delete. Omitted update keywords
    /// preserve the old words, while [] explicitly clears them.
    public var keywords: [String]? { after?.keywords }
    private let operation: MemoryOperation

    fileprivate init(baseRevision: UUID, toolName: String, op: MemoryToolOperation, targetID: UUID?,
                     quote: String, before: MemoryToolValue?, after: MemoryToolValue?, operation: MemoryOperation) {
        id = UUID(); self.baseRevision = baseRevision; self.toolName = toolName; self.op = op
        self.targetID = targetID; self.quote = quote; self.before = before; self.after = after; self.operation = operation
    }

    /// Apply to the host's disposable copy. Persist the entire encrypted snapshot
    /// before publishing state, note or resultJSON. No model text can approve this.
    public func apply(to state: inout MemoryState, conversationID: String? = nil, now: Date) throws -> MemoryToolReceipt {
        let note = try state.applyToolOperation(operation, baseRevision: baseRevision, conversationID: conversationID, now: now)
        let item = state.memories.first { $0.id == note.memoryID }
        return MemoryToolReceipt(op: op, note: note, item: item)
    }
}

public struct MemoryToolReceipt: Encodable, Sendable {
    public let ok: Bool
    public let op: String?
    public let id: UUID
    public let kind: MemoryKind?
    public let status: MemoryStatus?
    public let deleted: Bool?
    /// Host UI only; never serialized into the model result.
    public let note: MemoryNote
    private enum CodingKeys: String, CodingKey { case ok, op, id, kind, status, deleted }
    fileprivate init(op: MemoryToolOperation, note: MemoryNote, item: MemoryItem?) {
        ok = true; self.op = op == .add ? nil : op.rawValue; id = note.memoryID
        kind = item?.kind; status = item?.status; deleted = op == .delete ? true : nil; self.note = note
    }
    public func resultJSON() throws -> String { try memoryToolJSON(self) }
}

private func memoryToolJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

enum MemoryArgumentValue { case string(String), strings([String]) }

/// Exact flat tool grammar. Shared with profile_edit; duplicate decoded keys,
/// unknown keys, wrong types and trailing JSON cannot be lost to re-encoding.
struct MemoryArgumentParser {
    private let bytes: [UInt8]
    private let strings: Set<String>
    private let arrays: Set<String>
    private var offset = 0
    init(_ text: String, strings: Set<String>, arrays: Set<String> = []) {
        bytes = Array(text.utf8); self.strings = strings; self.arrays = arrays
    }
    mutating func parse() throws -> [String: MemoryArgumentValue] {
        var values: [String: MemoryArgumentValue] = [:], seen = Set<String>()
        try require(0x7B)
        if !take(0x7D) {
            while true {
                let key = try string()
                guard (strings.contains(key) || arrays.contains(key)), seen.insert(key).inserted else {
                    throw MemoryToolError.invalidArguments
                }
                try require(0x3A); whitespace()
                if bytes.dropFirst(offset).starts(with: [0x6E, 0x75, 0x6C, 0x6C]) { offset += 4 }
                else if strings.contains(key) { values[key] = .string(try string()) }
                else {
                    try require(0x5B)
                    var list: [String] = []
                    if !take(0x5D) {
                        while true {
                            list.append(try string())
                            if take(0x5D) { break }
                            try require(0x2C)
                        }
                    }
                    values[key] = .strings(list)
                }
                if take(0x7D) { break }
                try require(0x2C)
            }
        }
        whitespace()
        guard offset == bytes.count else { throw MemoryToolError.invalidArguments }
        return values
    }
    private mutating func string() throws -> String {
        whitespace(); let start = offset
        guard take(0x22) else { throw MemoryToolError.invalidArguments }
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 0x22 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw MemoryToolError.invalidArguments }
            }
            if byte == 0x5C {
                guard offset < bytes.count else { throw MemoryToolError.invalidArguments }
                offset += 1
            }
        }
        throw MemoryToolError.invalidArguments
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
        guard take(byte) else { throw MemoryToolError.invalidArguments }
    }
}

// Shared pinned specifics heuristic; unlike extraction it has no grammar allowlist.
enum MemoryToolGrounding {
    static func normalizedQuote(_ value: String) -> String {
        MemorySafety.normalized(value).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let normalized = MemorySafety.normalized(value)
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
