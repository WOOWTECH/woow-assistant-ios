import XCTest
@testable import AssistantPersistence

final class EncryptedLearningFileTests: XCTestCase {
    final class Keys: LearningKeyStore {
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

    func testEncryptedRoundTripAndKeyRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning.vault")
        let keys = Keys()
        let vault = EncryptedLearningFile(url: file, keys: keys)
        XCTAssertNil(try vault.load([String].self))
        try vault.save(["private-memory-marker"])
        let oldKeys = keys.values
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private-memory-marker"))
        let reopened = EncryptedLearningFile(url: file, keys: keys)
        XCTAssertEqual(try reopened.load([String].self), ["private-memory-marker"])
        XCTAssertTrue(try reopened.save([String](), rotateKey: true))
        XCTAssertEqual(keys.values.count, 1)
        XCTAssertNotEqual(Set(keys.values.keys), Set(oldKeys.keys))
        XCTAssertEqual(try reopened.load([String].self), [])
    }

    func testUnreadableVaultCannotBeOverwrittenUntilExplicitClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning.vault")
        let keys = Keys()
        let vault = EncryptedLearningFile(url: file, keys: keys)
        _ = try vault.load([String].self)
        try vault.save(["preserve-me"])
        let original = try Data(contentsOf: file)
        keys.values.removeAll()
        XCTAssertThrowsError(try vault.load([String].self))
        XCTAssertThrowsError(try vault.save([String]()))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try vault.save([String](), rotateKey: true))
        XCTAssertEqual(try vault.load([String].self), [])
    }

    func testFailedKeyWriteKeepsOriginalBytesAndData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning.vault")
        let keys = Keys()
        let vault = EncryptedLearningFile(url: file, keys: keys)
        _ = try vault.load([String].self)
        try vault.save(["original"])
        let original = try Data(contentsOf: file)
        keys.rejectWrites = true
        XCTAssertThrowsError(try vault.save([String](), rotateKey: true))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try vault.load([String].self), ["original"])
    }

    func testTamperAndSchemaFailuresNeverPublishEmptyData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("learning.vault")
        let keys = Keys()
        let vault = EncryptedLearningFile(url: file, keys: keys)
        _ = try vault.load([String].self)
        try vault.save(["original"])
        XCTAssertThrowsError(try vault.load([Int].self))
        XCTAssertThrowsError(try vault.save([String]()))
        _ = try vault.load([String].self)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["keyID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        XCTAssertThrowsError(try vault.load([String].self))
        XCTAssertThrowsError(try vault.save([String]()))
    }
}
