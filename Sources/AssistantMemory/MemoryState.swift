import Foundation

/// Value semantics: mutate a copy, persist it atomically, then publish that copy.
/// No disk/network access. Every visible change invalidates pending extraction plans.
public struct MemoryState: Codable, Equatable, Sendable {
    public private(set) var memories: [MemoryItem]
    public private(set) var preferences: MemoryPreferences
    public private(set) var revision: UUID
    private var undos: [Undo] = []

    public init(preferences: MemoryPreferences = .init()) {
        memories = []; self.preferences = preferences; revision = UUID()
    }

    public init(memories: [MemoryItem], preferences: MemoryPreferences = .init()) throws {
        try Self.validate(memories)
        self.memories = memories; self.preferences = preferences; revision = UUID()
    }

    private enum CodingKeys: String, CodingKey { case memories, preferences, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let items = try values.decode([MemoryItem].self, forKey: .memories)
        try Self.validate(items)
        memories = items
        preferences = try values.decodeIfPresent(MemoryPreferences.self, forKey: .preferences) ?? .init()
        revision = try values.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(memories, forKey: .memories)
        try values.encode(preferences, forKey: .preferences)
        try values.encode(revision, forKey: .revision)
        // Undo snapshots intentionally live only in RAM, like the reference implementation.
    }

    public static func == (lhs: MemoryState, rhs: MemoryState) -> Bool {
        lhs.memories == rhs.memories && lhs.preferences == rhs.preferences && lhs.revision == rhs.revision
    }

    public mutating func setPreferences(_ value: MemoryPreferences) {
        guard value != preferences else { return }
        preferences = value; revision = UUID()
    }

    @discardableResult
    public mutating func add(kind: MemoryKind, content: String, keywords: [String] = [], now: Date = Date()) throws -> MemoryNote {
        try add(kind: kind, content: content, keywords: keywords, source: .init(type: "manual", at: now), now: now)
    }

    @discardableResult
    public mutating func edit(id: UUID, content: String, keywords: [String]? = nil, now: Date = Date()) throws -> MemoryNote {
        try edit(id: id, content: content, keywords: keywords, source: .init(type: "manual", at: now), now: now)
    }

    public mutating func setPinned(id: UUID, pinned: Bool) throws {
        let index = try index(id)
        guard memories[index].pinned != pinned else { return }
        memories[index] = memories[index].changing(pinned: pinned); revision = UUID()
    }

    @discardableResult
    public mutating func delete(id: UUID) throws -> MemoryNote {
        let index = try index(id)
        let before = memories.remove(at: index)
        return remember(before: before, after: nil)
    }

    public mutating func approve(id: UUID) throws {
        let index = try index(id)
        guard memories[index].kind == .procedure, memories[index].status == .pending else { throw MemoryError.notPending }
        memories[index] = memories[index].changing(status: .active); revision = UUID()
    }

    /// Read-only eligibility for an undo card. Exercise the real undo rules on
    /// a disposable value so stale, capacity and duplicate checks cannot drift.
    /// Neither the live revision nor its RAM token is changed or consumed.
    public func canUndo(token: UUID) -> Bool {
        var copy = self
        return (try? copy.undo(token: token)) == true
    }

    /// A late undo must not remove a subsequently edited or approved memory.
    @discardableResult
    public mutating func undo(token: UUID) throws -> Bool {
        guard let position = undos.firstIndex(where: { $0.token == token }) else { return false }
        let change = undos[position]
        if let after = change.after {
            guard let current = memories.first(where: { $0.id == after.id }),
                  current.content == after.content, current.keywords == after.keywords,
                  current.source == after.source, current.status == after.status,
                  current.updatedAt == after.updatedAt else { return false }
            if let before = change.before {
                let restored = before.changing(pinned: current.pinned, lastUsedAt: current.lastUsedAt, useCount: current.useCount)
                memories = memories.map { $0.id == restored.id ? restored : $0 }
            } else { memories.removeAll { $0.id == after.id } }
        } else if let before = change.before {
            guard !memories.contains(where: { $0.id == before.id }) else { return false }
            guard memories.count < 500 else { throw MemoryError.capacityExceeded }
            guard !memories.contains(where: { $0.kind == before.kind && $0.content == before.content }) else { throw MemoryError.duplicate }
            memories.append(before)
        }
        undos.remove(at: position); revision = UUID()
        return true
    }

    public mutating func clearAll() {
        memories = []; undos = []; revision = UUID()
    }

    public mutating func markUsed(_ ids: [UUID], now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else { throw MemoryError.invalidState }
        guard preferences.useMemory else { return }
        let requested = Set(ids)
        var changed = false
        memories = memories.map { item in
            guard requested.contains(item.id), item.status == .active else { return item }
            changed = true
            return item.changing(lastUsedAt: now, useCount: item.useCount < Int.max ? item.useCount + 1 : Int.max)
        }
        if changed { revision = UUID() }
    }

    @discardableResult
    public mutating func apply(plan: MemoryExtractionPlan, now: Date = Date()) throws -> [MemoryNote] {
        guard revision == plan.baseRevision else { throw MemoryError.stalePlan }
        guard preferences.useMemory && preferences.autoRemember else { throw MemoryError.disabled }
        var copy = self
        var notes: [MemoryNote] = []
        for operation in plan.operations {
            switch operation {
            case .add(let kind, let content, let keywords, let quote):
                notes.append(try copy.add(kind: kind, content: content, keywords: keywords,
                                         source: .init(type: "user_said", quote: quote, conversationID: plan.conversationID, at: now), now: now))
            case .update(let id, let content, let keywords, let quote):
                notes.append(try copy.edit(id: id, content: content, keywords: keywords,
                                          source: .init(type: "user_said", quote: quote, conversationID: plan.conversationID, at: now), now: now))
            case .forget(let id): notes.append(try copy.delete(id: id))
            }
        }
        self = copy // All-or-nothing, even if a later operation exceeds capacity.
        return notes
    }

    /// Only validated MemoryToolReview values reach this sourceful entry point
    /// from outside AssistantMemory. Explicit tools work with autoRemember off.
    /// The host still persists a disposable state before publishing its note.
    mutating func applyToolOperation(_ operation: MemoryOperation, baseRevision: UUID,
                                     conversationID: String?, now: Date) throws -> MemoryNote {
        guard preferences.useMemory else { throw MemoryToolError.disabled }
        guard revision == baseRevision else { throw MemoryToolError.staleRevision }
        guard now.timeIntervalSince1970.isFinite, (conversationID?.utf16.count ?? 0) <= 256 else {
            throw MemoryError.invalidState
        }
        var copy = self
        let note: MemoryNote
        switch operation {
        case .add(let kind, let content, let keywords, let quote):
            note = try copy.add(kind: kind, content: content, keywords: keywords,
                source: .init(type: "user_said", quote: quote, conversationID: conversationID, at: now), now: now)
        case .update(let id, let content, let keywords, let quote):
            note = try copy.edit(id: id, content: content, keywords: keywords,
                source: .init(type: "user_said", quote: quote, conversationID: conversationID, at: now), now: now)
        case .forget(let id): note = try copy.delete(id: id)
        }
        self = copy
        return note
    }

    private mutating func add(kind: MemoryKind, content: String, keywords: [String], source: MemorySource, now: Date) throws -> MemoryNote {
        let text = MemorySafety.clean(content)
        let words = try MemorySafety.keywords(keywords)
        try MemorySafety.validate(content: text, keywords: words, source: source)
        guard now.timeIntervalSince1970.isFinite else { throw MemoryError.invalidState }
        guard memories.count < 500 else { throw MemoryError.capacityExceeded }
        guard !memories.contains(where: { $0.kind == kind && $0.content == text }) else { throw MemoryError.duplicate }
        let item = MemoryItem(id: UUID(), kind: kind, content: text, keywords: words, source: source,
                              status: kind == .procedure ? .pending : .active, pinned: false,
                              createdAt: now, updatedAt: now, lastUsedAt: nil, useCount: 0, replaces: nil)
        memories.append(item)
        return remember(before: nil, after: item)
    }

    private mutating func edit(id: UUID, content: String, keywords: [String]?, source: MemorySource, now: Date) throws -> MemoryNote {
        let index = try index(id)
        let before = memories[index]
        let text = MemorySafety.clean(content)
        let words = try keywords.map(MemorySafety.keywords) ?? before.keywords
        try MemorySafety.validate(content: text, keywords: words, source: source)
        guard now.timeIntervalSince1970.isFinite else { throw MemoryError.invalidState }
        guard !memories.contains(where: { $0.id != id && $0.kind == before.kind && $0.content == text }) else { throw MemoryError.duplicate }
        let item = before.changing(content: text, keywords: words, source: source,
                                   status: before.kind == .procedure && source.type != "manual" ? .pending : before.status,
                                   updatedAt: now, replaces: text != before.content ? before.content : before.replaces)
        memories[index] = item
        return remember(before: before, after: item)
    }

    private func index(_ id: UUID) throws -> Int {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { throw MemoryError.notFound }
        return index
    }

    private mutating func remember(before: MemoryItem?, after: MemoryItem?) -> MemoryNote {
        let token = UUID()
        undos.append(Undo(token: token, before: before, after: after))
        if undos.count > 50 { undos.removeFirst(undos.count - 50) }
        revision = UUID()
        let kind: MemoryNoteKind = after == nil ? .forgot : after?.status == .pending ? .pending : before == nil ? .added : .updated
        return MemoryNote(kind: kind, memoryID: (after ?? before)!.id, undoToken: token,
                          pendingID: after?.status == .pending ? after?.id : nil)
    }

    private static func validate(_ memories: [MemoryItem]) throws {
        guard memories.count <= 500, Set(memories.map(\.id)).count == memories.count else { throw MemoryError.invalidState }
        for item in memories {
            try MemorySafety.validate(content: item.content, keywords: item.keywords, source: item.source)
            guard item.content == MemorySafety.clean(item.content), item.keywords == (try MemorySafety.keywords(item.keywords)),
                  item.kind == .procedure || item.status == .active, item.useCount >= 0,
                  item.createdAt.timeIntervalSince1970.isFinite, item.updatedAt.timeIntervalSince1970.isFinite,
                  item.lastUsedAt?.timeIntervalSince1970.isFinite ?? true else { throw MemoryError.invalidState }
            if let previous = item.replaces {
                try MemorySafety.validate(content: previous, keywords: [], source: .init(type: "manual", at: item.updatedAt))
            }
        }
    }

    private struct Undo: Sendable { let token: UUID; let before: MemoryItem?; let after: MemoryItem? }
}
