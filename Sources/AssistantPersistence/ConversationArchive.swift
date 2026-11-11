import Foundation

public enum ConversationArchiveError: Error, Equatable {
    case invalidData, full, destinationMismatch, staleConversation, unavailable
}

/// Nonsecret identity, including the Keychain account UUID, never its credential.
public struct ConversationDestination: Codable, Equatable, Sendable {
    public let baseURL: String
    public let model: String
    public let credentialAccount: UUID

    public init(baseURL: String, model: String, credentialAccount: UUID) throws {
        guard baseURL.utf8.count <= 4096, model.utf8.count <= 1024,
              let url = URLComponents(string: baseURL), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.url != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !baseURL.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ConversationArchiveError.invalidData }
        self.baseURL = baseURL; self.model = model; self.credentialAccount = credentialAccount
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, credentialAccount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: c.decode(String.self, forKey: .baseURL),
                      model: c.decode(String.self, forKey: .model),
                      credentialAccount: c.decode(UUID.self, forKey: .credentialAccount))
    }
}

/// Only a completed pair. No roles, commands, approvals, credentials or receipts
/// can be decoded into executable state from this representation.
public struct ArchivedConversationTurn: Codable, Equatable, Sendable {
    public let userID: UUID
    public let assistantID: UUID
    public let userText: String
    public let assistantText: String
    public let pdf: ArchivedPDFAnswer?

    public init(userID: UUID = UUID(), assistantID: UUID = UUID(), userText: String, assistantText: String,
                pdf: ArchivedPDFAnswer? = nil) throws {
        guard userID != assistantID,
              [userText, assistantText].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.utf8.count <= ConversationArchive.maximumMessageBytes })
        else { throw ConversationArchiveError.invalidData }
        self.userID = userID; self.assistantID = assistantID
        self.userText = userText; self.assistantText = assistantText
        self.pdf = pdf
    }

    private enum CodingKeys: String, CodingKey { case userID, assistantID, userText, assistantText, pdf }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(userID: c.decode(UUID.self, forKey: .userID), assistantID: c.decode(UUID.self, forKey: .assistantID),
                      userText: c.decode(String.self, forKey: .userText), assistantText: c.decode(String.self, forKey: .assistantText),
                      pdf: c.decodeIfPresent(ArchivedPDFAnswer.self, forKey: .pdf))
    }
}

public struct ArchivedConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let destination: ConversationDestination
    public let updatedAt: Date
    public let turns: [ArchivedConversationTurn]
    public var title: String { String(turns[0].userText.prefix(60)) }

    public init(id: UUID, destination: ConversationDestination, updatedAt: Date, turns: [ArchivedConversationTurn]) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite,
              !turns.isEmpty, turns.count <= ConversationArchive.maximumTurnsPerConversation,
              Set(turns.flatMap { [$0.userID, $0.assistantID] }).count == turns.count * 2
        else { throw ConversationArchiveError.invalidData }
        self.id = id; self.destination = destination; self.updatedAt = updatedAt; self.turns = turns
    }

    private enum CodingKeys: String, CodingKey { case id, destination, updatedAt, turns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), destination: c.decode(ConversationDestination.self, forKey: .destination),
                      updatedAt: c.decode(Date.self, forKey: .updatedAt), turns: c.decode([ArchivedConversationTurn].self, forKey: .turns))
    }
}

/// Bounded whole snapshot, persisted atomically by the host. Never evicts data.
public struct ConversationArchive: Codable, Equatable, Sendable {
    public static let maximumConversations = 50
    public static let maximumTurnsPerConversation = 200
    public static let maximumMessageBytes = 1024 * 1024
    public static let maximumEncodedBytes = 3 * 1024 * 1024
    public private(set) var conversations: [ArchivedConversation] = []
    private let version = 2
    public init() {}

    public mutating func save(_ record: ArchivedConversation) throws {
        var next = self
        if let index = next.conversations.firstIndex(where: { $0.id == record.id }) {
            let prior = next.conversations[index]
            guard prior.destination == record.destination else { throw ConversationArchiveError.destinationMismatch }
            guard record.turns.count >= prior.turns.count,
                  Array(record.turns.prefix(prior.turns.count)) == prior.turns
            else { throw ConversationArchiveError.staleConversation }
            next.conversations[index] = record
        } else { next.conversations.append(record) }
        try next.validate()
        self = next
    }

    public mutating func delete(id: UUID) throws {
        guard conversations.contains(where: { $0.id == id }) else { throw ConversationArchiveError.staleConversation }
        conversations.removeAll { $0.id == id }
    }

    private func validate() throws {
        guard conversations.count <= Self.maximumConversations else { throw ConversationArchiveError.full }
        guard Set(conversations.map(\.id)).count == conversations.count else { throw ConversationArchiveError.invalidData }
        let entries = conversations.flatMap { $0.turns.flatMap { [$0.userID, $0.assistantID] } }
        guard Set(entries).count == entries.count else { throw ConversationArchiveError.invalidData }
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else { throw ConversationArchiveError.full }
    }

    private enum CodingKeys: String, CodingKey { case version, conversations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == 2 else { throw ConversationArchiveError.invalidData }
        conversations = try c.decode([ArchivedConversation].self, forKey: .conversations)
        guard storedVersion != 1 || conversations.allSatisfy({ $0.turns.allSatisfy { $0.pdf == nil } })
        else { throw ConversationArchiveError.invalidData }
        try validate()
    }
}
