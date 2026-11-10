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
        var parser = MemoryArgumentParser(argumentsJSON, strings: ["op", "text", "match", "quote"])
        let fields: [String: String]
        do {
            fields = try parser.parse().mapValues { value in
                guard case .string(let text) = value else { throw UserProfileToolError.invalidArguments }
                return text
            }
        } catch { throw UserProfileToolError.invalidArguments }
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
        let normalizedQuote = MemoryToolGrounding.normalizedQuote(quote)
        guard normalizedQuote.utf16.count >= 2,
              utterances.contains(where: {
                  MemoryToolGrounding.normalizedQuote($0).range(of: normalizedQuote, options: .literal) != nil
              }) else { throw UserProfileToolError.quoteNotFromUser }
        if let text, !MemoryToolGrounding.supported(text, quote: quote, utterances: utterances) {
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
