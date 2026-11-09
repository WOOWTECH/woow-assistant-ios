import CryptoKit
import Foundation

public protocol LearningKeyStore {
    func read(id: String) throws -> Data?
    func insert(_ key: Data, id: String) throws
    func remove(id: String) throws
    /// Implementations must scope this to the learning vault's own service.
    func removeAll(except id: String) throws
}

public enum LearningFileError: Error, Equatable {
    case unavailable, invalidData, tooLarge, missingKey, notLoaded
}

/// Single-owner, serialized use only. The App owns this on MainActor.
/// A failed load never authorizes replacing an unreadable vault with an empty one.
public final class EncryptedLearningFile {
    public static let maximumBytes = 8 * 1024 * 1024
    private struct Envelope: Codable {
        let version: Int
        let keyID: String
        let sealed: Data
    }
    private let url: URL
    private let keys: any LearningKeyStore
    private var loaded = false
    private var currentKeyID: String?

    public init(url: URL, keys: any LearningKeyStore) {
        self.url = url
        self.keys = keys
    }

    public func load<T: Decodable>(_ type: T.Type) throws -> T? {
        loaded = false
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let failure = error as NSError
            // fileExists(false) also covers access errors. Only a confirmed ENOENT
            // permits a fresh vault; locked/unreadable data must stay write-blocked.
            if failure.domain == NSCocoaErrorDomain &&
                (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) {
                currentKeyID = nil; loaded = true
                return nil
            }
            throw LearningFileError.unavailable
        }
        do {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LearningFileError.invalidData }
            guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else {
                throw LearningFileError.tooLarge
            }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= Self.maximumBytes else { throw LearningFileError.tooLarge }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, UUID(uuidString: envelope.keyID) != nil else { throw LearningFileError.invalidData }
            guard let key = try keys.read(id: envelope.keyID), key.count == 32 else { throw LearningFileError.missingKey }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                using: SymmetricKey(data: key), authenticating: Self.aad(envelope.keyID))
            let result = try JSONDecoder().decode(type, from: plaintext)
            currentKeyID = envelope.keyID
            loaded = true
            return result
        } catch let error as LearningFileError { throw error }
        catch { throw LearningFileError.unavailable }
    }

    /// Returns false only when saving succeeded but removal of retired keys failed.
    /// rotateKey is reserved for the user's twice-confirmed clear-all action.
    @discardableResult
    public func save<T: Encodable>(_ value: T, rotateKey: Bool = false) throws -> Bool {
        guard loaded || rotateKey else { throw LearningFileError.notLoaded }
        let plaintext = try JSONEncoder().encode(value)
        guard plaintext.count <= Self.maximumBytes / 2 else { throw LearningFileError.tooLarge }
        let isNewKey = rotateKey || currentKeyID == nil
        let id = isNewKey ? UUID().uuidString : currentKeyID!
        let key: Data
        if isNewKey {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keys.insert(key, id: id)
        } else {
            guard let existing = try keys.read(id: id), existing.count == 32 else { throw LearningFileError.missingKey }
            key = existing
        }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: Self.aad(id))
            guard let combined = sealed.combined else { throw LearningFileError.invalidData }
            let encoded = try JSONEncoder().encode(Envelope(version: 1, keyID: id, sealed: combined))
            guard encoded.count <= Self.maximumBytes else { throw LearningFileError.tooLarge }
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // ThisDeviceOnly keys cannot decrypt a restored backup; keep both ciphertext
            // and its parent out of backup rather than creating an unrecoverable restore.
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            try encoded.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try encoded.write(to: url, options: .atomic)
            #endif
        } catch {
            if isNewKey { try? keys.remove(id: id) }
            throw LearningFileError.unavailable
        }
        currentKeyID = id
        loaded = true
        if rotateKey {
            do { try keys.removeAll(except: id) }
            catch { return false }
        }
        return true
    }

    private static func aad(_ id: String) -> Data {
        Data("io.woowtech.assistant.learning.v1:\(id)".utf8)
    }
}
