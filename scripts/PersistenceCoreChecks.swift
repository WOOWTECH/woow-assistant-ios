import AssistantPersistence
import Foundation

private final class Keys: LearningKeyStore {
    var values: [String: Data] = [:]
    var rejectWrites = false
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws {
        if rejectWrites { throw LearningFileError.unavailable }
        values[id] = key
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

@main struct PersistenceCoreChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woow-vault-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning.vault")
        let keys = Keys()
        let vault = EncryptedLearningFile(url: file, keys: keys)
        precondition(tryValue { try vault.load([String].self) } == nil)
        try vault.save(["private-marker"])
        let original = try Data(contentsOf: file)
        precondition(!String(decoding: original, as: UTF8.self).contains("private-marker"))
        let reopened = EncryptedLearningFile(url: file, keys: keys)
        precondition(tryValue { try reopened.load([String].self) } == ["private-marker"])
        keys.rejectWrites = true
        expectFailure { try reopened.save([String](), rotateKey: true) }
        precondition(tryValue { try Data(contentsOf: file) } == original)
        keys.rejectWrites = false
        let previousIDs = Set(keys.values.keys)
        try reopened.save([String](), rotateKey: true)
        precondition(keys.values.count == 1 && Set(keys.values.keys) != previousIDs)
        precondition(tryValue { try reopened.load([String].self) } == [])
        keys.values.removeAll()
        expectFailure { try reopened.load([String].self) }
        let unreadable = try Data(contentsOf: file)
        expectFailure { try reopened.save(["must not overwrite"]) }
        precondition(tryValue { try Data(contentsOf: file) } == unreadable)
        try reopened.save([String](), rotateKey: true)
        precondition(tryValue { try reopened.load([String].self) } == [])
        print("PASS: encrypted persistence round-trip, key rotation, failed-write preservation, unavailable-key guard, explicit reset")
    }
    private static func tryValue<T>(_ operation: () throws -> T) -> T { try! operation() }
    private static func expectFailure<T>(_ operation: () throws -> T) {
        do { _ = try operation(); fatalError("Expected failure") } catch {}
    }
}
