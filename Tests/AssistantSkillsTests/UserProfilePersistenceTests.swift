#if USER_PROFILE_STORE_STANDALONE || canImport(WoowAssistant)
import Foundation
import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import AssistantBrowser

// Only the unrelated browser tool catalog is substituted for this CLT harness.
// The production LearningStore, every state type and AES-GCM file are compiled
// unchanged. No browser/model requests or personal Keychain access are performed.
#if USER_PROFILE_STORE_STANDALONE
@MainActor enum BrowserSession { static let toolNames: Set<String> = [] }
#else
import XCTest
@testable import WoowAssistant
#endif

private final class ProfileTestKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var failReads = false
    var failInsert = false
    func read(id: String) throws -> Data? {
        if failReads { throw LearningFileError.unavailable }
        return values[id]
    }
    func insert(_ key: Data, id: String) throws {
        if failInsert { throw LearningFileError.unavailable }
        values[id] = key
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

enum UserProfilePersistenceChecks {
    struct Failure: Error { let message: String }
    struct Legacy: Codable {
        var version: Int
        var memory = MemoryState()
        var skills = SkillsState()
        var websites: WebsiteKnowledgeState?
        var routes: WebRouteState?
    }
    struct Malformed: Encodable {
        let version = 2
        let memory = MemoryState()
        let skills = SkillsState()
        let profile = "malformed profile must not become an empty default"
    }
    @MainActor static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1
            if try !condition() { throw Failure(message: message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-profile-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("learning.vault"), keys = ProfileTestKeys()
        func vault(_ url: URL? = nil) -> EncryptedLearningFile { .init(url: url ?? file, keys: keys) }
        let store = LearningStore(vault: vault())
        try check(store.available && store.profile.entries.isEmpty, "Confirmed missing vault loads fresh")
        let generation = store.generation
        var cancelled = false
        store.onUserChange = { cancelled = true }
        try check(store.mutateProfile { try $0.add(text: "Prefer quiet hotels") }, "Profile save succeeds")
        try check(store.generation == generation && !cancelled, "Profile edits do not invalidate/cancel current run")
        let originalProfile = store.profile
        let originalBytes = try Data(contentsOf: file)
        try check(!String(decoding: originalBytes, as: UTF8.self).contains("Prefer quiet hotels"), "Profile is encrypted on disk")
        let frozen = store.contextMessages(for: "Where to stay")
        try check(frozen.count == 1 && frozen[0].role == "user", "Profile context injected as reference")
        try check(frozen[0].content.contains("what the user says in this turn takes precedence"), "Turn precedence")
        try check(store.mutateProfile { try $0.replace(segment: "quiet", replacement: "central") }, "Replace persists")
        try check(frozen[0].content.contains("quiet") && !frozen[0].content.contains("central"), "Existing run context frozen")
        try check(store.contextMessages(for: "Next run")[0].content.contains("central"), "Next run gets latest profile")
        try check(LearningStore(vault: vault()).profile == store.profile, "Relaunch restores profile and superseded history")
        let beforeFailure = store.profile, bytesBeforeFailure = try Data(contentsOf: file)
        keys.failReads = true
        try check(!store.mutateProfile { try $0.add(text: "Must not publish") }, "Key read failure rejects save")
        try check(store.profile == beforeFailure && store.error != nil, "Failed save leaves published profile unchanged")
        try check(store.notice == nil, "Failed save cannot leave a previous success notice visible")
        try check(try Data(contentsOf: file) == bytesBeforeFailure, "Failed save leaves existing ciphertext unchanged")
        keys.failReads = false
        try check(LearningStore(vault: vault()).profile == beforeFailure, "Failed write does not appear on relaunch")
        try check(!store.mutateProfile {
            try $0.add(text: "Must roll back first operation")
            try $0.add(text: "Two. Sentences.")
        }, "A later rejected mutation rejects the whole value transaction")
        try check(store.profile == beforeFailure && (try Data(contentsOf: file)) == bytesBeforeFailure,
                  "A rejected batch changes neither published state nor ciphertext")

        let backup = root.appendingPathComponent("backup.vault")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try check(!store.mutateProfile { try $0.delete(segment: "central") }, "Actual atomic file replacement failure rejects")
        try check(store.profile == beforeFailure, "Filesystem failure cannot publish deletion")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try check(try Data(contentsOf: file) == bytesBeforeFailure, "Restored prior ciphertext is byte-identical")

        try check(store.updatePreferences { $0.useMemory = false }, "Master switch saved")
        try check(store.contextMessages(for: "Where to stay").isEmpty, "Master switch suppresses profile context")
        try check(store.profile == beforeFailure, "Switch preserves saved profile")
        let disabled = LearningStore(vault: vault())
        try check(!disabled.memory.preferences.useMemory && disabled.contextMessages(for: "test").isEmpty,
                  "Switch remains off on relaunch")
        try check(store.updatePreferences { $0.useMemory = true; $0.autoRemember = false }, "Memory enabled without extraction")
        try check(store.contextMessages(for: "test").count == 1, "Auto-remember toggle does not disable manual profile")
        try check(store.mutateMemory { try $0.add(kind: .fact, content: "Memory marker") }, "Memory saves with profile")
        let markdown = """
        ---
        name: profile-test-notes
        description: Organize notes.
        ---
        ## Entry
        Notes.
        ## Steps
        List useful details.
        ## Pitfalls
        Missing details.
        ## Success criteria
        A summary.
        ## When to stop
        Ask the user.
        """
        try check(store.mutateSkills {
            let draft = try $0.importMarkdown(markdown, availableToolNames: [])
            _ = try $0.approveDraft(id: draft.id, availableToolNames: [])
        }, "Skill saves with profile")
        let date = Date(timeIntervalSince1970: 1000)
        let page = PageSnapshot(url: URL(string: "https://example.com/guide")!, title: "Guide", visibleText: "Use the guide", capturedAt: date)
        let evidence = try WebsiteLessonEvidence(snapshot: page, quote: "Use the guide")
        let step = try WebRouteStep(kind: .observe, snapshot: page, evidenceQuote: "Use the guide")
        let task = try WebTaskEvidence(outcome: .succeeded, confirmed: true, summary: "Read guide", completedAt: date)
        try check(store.mutateWeb { websites, routes in
            try websites.addManual(text: "Use the guide", evidence: evidence, now: date)
            try routes.record(intent: "Read guide", steps: [step], task: task)
        }, "Website save preserves profile")
        let expectedMemory = store.memory, expectedSkills = store.skills
        let expectedWebsites = store.websites, expectedRoutes = store.routes
        try check(store.mutateProfile { try $0.add(text: "Prefer tea") }, "Profile persists alongside all learning fields")
        let reopened = LearningStore(vault: vault())
        try check(reopened.profile == store.profile && reopened.memory == expectedMemory && reopened.skills == expectedSkills
                  && reopened.websites == expectedWebsites && reopened.routes == expectedRoutes, "No sibling fields lost on profile save/relaunch")
        let context = store.contextMessages(for: "notes")
        try check(context.first?.content.contains("User profile") == true, "Profile precedes retrieved memory and skill references")
        try check(store.updatePreferences { $0.useMemory = false }, "Master off with approved skills")
        let skillContext = store.contextMessages(for: "notes")
        try check(!skillContext.isEmpty && !skillContext.contains { $0.content.contains("User profile") },
                  "Approved skills remain independent of master memory switch")

        let beforeClear = store.profile, keysBeforeClear = Set(keys.values.keys), bytesBeforeClear = try Data(contentsOf: file)
        keys.failInsert = true
        try check(!store.clearAll(), "Rotation key failure rejects clear-all")
        try check(store.profile == beforeClear && store.skills == expectedSkills && store.websites == expectedWebsites,
                  "Failed clear-all preserves profile and sibling states")
        try check(try Data(contentsOf: file) == bytesBeforeClear && Set(keys.values.keys) == keysBeforeClear, "Failed rotation preserves vault/key")
        keys.failInsert = false
        try check(store.clearAll(), "Confirmed clear-all succeeds")
        try check(store.profile.entries.isEmpty && store.memory.memories.isEmpty && store.skills.installed.isEmpty
                  && store.websites.lessons.isEmpty && store.routes.routes.isEmpty, "Clear-all removes profile history and all learning data")
        try check(keys.values.count == 1 && Set(keys.values.keys) != keysBeforeClear, "Clear-all actually rotates and retires keys")
        let cleared = LearningStore(vault: vault())
        try check(cleared.profile == store.profile && cleared.profile.entries.isEmpty, "Cleared exact profile revision survives relaunch")
        try check(!cleared.memory.preferences.useMemory, "Clear-all preserves master switch")

        for version in [1, 2] {
            let url = root.appendingPathComponent("legacy-\(version).vault"), legacyVault = vault(url)
            _ = try legacyVault.load(Legacy.self)
            var legacy = Legacy(version: version)
            if version == 2 { legacy.websites = expectedWebsites; legacy.routes = expectedRoutes }
            try legacyVault.save(legacy)
            let migrated = LearningStore(vault: vault(url))
            try check(migrated.available && migrated.profile.entries.isEmpty, "Legacy v\(version) missing optional profile loads")
            try check(migrated.mutateProfile { try $0.add(text: "New profile") }, "Legacy v\(version) accepts profile")
            let roundtrip = LearningStore(vault: vault(url))
            try check(roundtrip.profile == migrated.profile, "Legacy v\(version) upgrade relaunch")
            if version == 2 {
                try check(roundtrip.websites == expectedWebsites && roundtrip.routes == expectedRoutes, "Legacy v2 website/route fields preserved")
            }
        }
        let malformedURL = root.appendingPathComponent("malformed.vault"), malformedVault = vault(malformedURL)
        _ = try malformedVault.load(Legacy.self)
        try malformedVault.save(Malformed())
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformed = LearningStore(vault: vault(malformedURL))
        try check(!malformed.available, "Malformed present profile fails load; no empty fallback")
        try check(!malformed.mutateProfile { try $0.add(text: "Do not overwrite") }, "Unreadable profile cannot authorize writes")
        try check(try Data(contentsOf: malformedURL) == malformedBytes, "Unreadable vault untouched")
        try check(malformed.contextMessages(for: "test").isEmpty, "Unreadable state contributes no context")

        // Authenticated content is required, even for a previously loaded owner.
        let validBytes = try Data(contentsOf: file)
        try Data("corrupted".utf8).write(to: file, options: .atomic)
        store.reload()
        try check(!store.available, "Corrupt reload disables store")
        try check(!store.mutateProfile { try $0.add(text: "Do not repair silently") }, "Corrupt reload cannot overwrite")
        try check(try Data(contentsOf: file) == Data("corrupted".utf8), "Corrupt original retained exactly")
        try validBytes.write(to: file, options: .atomic)
        store.reload()
        try check(store.available && store.profile.entries.isEmpty, "Valid restored vault reloads")
        try check(originalProfile.entries.count == 1, "Original value remains frozen throughout")
        return count
    }
}

#if !USER_PROFILE_STORE_STANDALONE
final class UserProfilePersistenceTests: XCTestCase {
    @MainActor func testEncryptedStoreRollbackRelaunchSwitchMigrationAndClear() throws {
        XCTAssertGreaterThan(try UserProfilePersistenceChecks.run(), 0)
    }
}
#endif
#endif
