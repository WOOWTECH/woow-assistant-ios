import Foundation

@main enum CheckUserProfileStore {
    @MainActor static func main() throws {
        let count = try UserProfilePersistenceChecks.run()
        print("PASS \(count) real LearningStore/AES-GCM assertions: rollback, relaunch, switches, migration, clear/key rotation, unreadable guards")
        print("Boundary: in-memory KeyStore and browser catalog shim only; no UI, Keychain or network test")
    }
}
