import AssistantPersistence
import Combine
import Foundation

@MainActor final class ConversationArchiveStore: ObservableObject {
    @Published private(set) var state = ConversationArchive()
    @Published private(set) var available = false
    @Published private(set) var error: String?
    private let vault: EncryptedLearningFile?

    var conversations: [ArchivedConversation] {
        state.conversations.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    init(vault: EncryptedLearningFile) { self.vault = vault; reload() }

    init() {
        do {
            let location = try Self.location(arguments: ProcessInfo.processInfo.arguments)
            let file = EncryptedLearningFile(url: location.url, keys: LearningKeychainStore(service: location.service))
            if location.reset { try file.save(ConversationArchive(), rotateKey: true) }
            vault = file
            reload()
        } catch {
            vault = nil
            self.error = Self.readFailure
        }
    }

    func reload() {
        do {
            guard let vault else { throw ConversationArchiveError.unavailable }
            let next = try vault.load(ConversationArchive.self) ?? ConversationArchive()
            state = next; available = true; error = nil
        } catch { available = false; self.error = Self.readFailure }
    }

    /// Match the exact pre-request row. Deletion/replacement cannot be undone by
    /// a late response, and unrelated conversation deletion does not block this row.
    func save(_ record: ArchivedConversation, expected: ArchivedConversation?) throws {
        guard available, let vault else { throw ConversationArchiveError.unavailable }
        guard state.conversations.first(where: { $0.id == record.id }) == expected else {
            throw ConversationArchiveError.staleConversation
        }
        var next = state
        try next.save(record)
        try vault.save(next)
        state = next; error = nil
    }

    @discardableResult func delete(id: UUID) -> Bool {
        do {
            guard available, let vault else { throw ConversationArchiveError.unavailable }
            var next = state
            try next.delete(id: id)
            try vault.save(next)
            state = next; error = nil
            return true
        } catch { self.error = "刪除未儲存，原對話仍保留。請解鎖後重試。"; return false }
    }

    private static let readFailure = "無法讀取加密對話，原檔保留且不會被覆寫。請解鎖後重新讀取。"

    static func location(arguments: [String], supportDirectory: () throws -> URL = {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }) throws -> (url: URL, service: String, reset: Bool) {
        var scope = "personal", reset = false
        #if DEBUG
        let flags = ["-UITestMode", "-LiveModelUITest", "-UITestNamespace", "-LiveModelUITestNamespace",
                     "-UITestResetStorage", "-LiveModelUITestCleanup"]
        if flags.contains(where: arguments.contains) {
            guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count <= 1 }),
                  arguments.contains("-UITestMode") != arguments.contains("-LiveModelUITest")
            else { throw ConversationArchiveError.invalidData }
            let live = arguments.contains("-LiveModelUITest")
            let flag = live ? "-LiveModelUITestNamespace" : "-UITestNamespace"
            let other = live ? "-UITestNamespace" : "-LiveModelUITestNamespace"
            guard !arguments.contains(other), live || !arguments.contains("-LiveModelUITestCleanup"),
                  let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1),
                  let id = UUID(uuidString: arguments[i + 1]) else { throw ConversationArchiveError.invalidData }
            scope = "test-" + id.uuidString
            reset = arguments.contains("-UITestResetStorage") || arguments.contains("-LiveModelUITestCleanup")
        }
        #endif
        let root = try supportDirectory()
        return (root.appendingPathComponent("Conversations/" + scope, isDirectory: true).appendingPathComponent("conversations.vault"),
                "io.woowtech.assistant.conversations.v1." + scope, reset)
    }
}
