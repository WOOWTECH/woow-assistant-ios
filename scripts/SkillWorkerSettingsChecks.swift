import AssistantSkills
import Foundation

private final class WorkerCheckCredentials: ModelCredentialStoring {
    var values: [String: String] = [:]
    var rejectInsert = false
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws {
        if rejectInsert { throw ModelSettingsError.unavailableKeychain }
        values[account] = key
    }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values.removeAll() }
}

@main enum SkillWorkerSettingsChecks {
    static func main() throws {
        let suite = "woow-worker-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = WorkerCheckCredentials()
        let store = SkillWorkerSettingsRepository(defaults: defaults, credentials: credentials)
        let endpoint = "https://worker.invalid/v1/extract-pdf"
        let token = "synthetic-worker-key"
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "WorkerSettingsCheck", code: count) }
            count += 1
        }
        func rejects(_ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }
            throw NSError(domain: "WorkerSettingsExpectedRejection", code: count)
        }
        try check(store.endpoint() == nil)
        try check(store.worker() == nil)
        try rejects { _ = try store.save(endpoint: endpoint, token: "") }
        try check(!store.save(endpoint: endpoint, token: token))
        try check(credentials.values.count == 1)
        try check(store.worker()?.destination == endpoint)
        let before = defaults.data(forKey: ModelSettingsRepository.configurationKey)!
        try check(!String(decoding: before, as: UTF8.self).contains(token))
        let reopened = SkillWorkerSettingsRepository(defaults: defaults, credentials: credentials)
        try check(reopened.worker()?.destination == endpoint)
        try check(!reopened.save(endpoint: endpoint + "-v2", token: ""))
        let current = defaults.data(forKey: ModelSettingsRepository.configurationKey)
        for url in ["http://worker.invalid/pdf", "https://different.invalid/pdf", "https://worker.invalid:444/pdf",
                    "https://worker.invalid/pdf?key=secret", "https://worker.invalid:bad/pdf", "https://user:password@worker.invalid/pdf"] {
            try rejects { _ = try store.save(endpoint: url, token: "") }
            try check(defaults.data(forKey: ModelSettingsRepository.configurationKey) == current)
            try check(credentials.values.values.first == token)
        }
        for invalid in ["has space", "line\r\nbreak", "中文", String(repeating: "x", count: 4097)] {
            try rejects { _ = try store.save(endpoint: endpoint, token: invalid) }
            try check(defaults.data(forKey: ModelSettingsRepository.configurationKey) == current)
        }
        credentials.rejectInsert = true
        try rejects { _ = try store.save(endpoint: endpoint, token: "replacement") }
        try check(defaults.data(forKey: ModelSettingsRepository.configurationKey) == current)
        try check(credentials.values.count == 1 && credentials.values.values.first == token)
        #if DEBUG
        for args in [["-UITestMode"], ["-LiveModelUITest"], ["-UITestNamespace", UUID().uuidString],
                     ["-UITestMode", "-LiveModelUITest", "-UITestNamespace", UUID().uuidString]] {
            try rejects { _ = try SkillWorkerSettingsRepository.makeDefault(arguments: args) }
        }
        let isolated = try SkillWorkerSettingsRepository.makeDefault(arguments: ["-UITestMode", "-UITestNamespace", UUID().uuidString])
        try check(isolated.endpoint() == nil)
        #endif
        try store.remove()
        try check(credentials.values.isEmpty && defaults.data(forKey: ModelSettingsRepository.configurationKey) == nil)
        print("PASS \(count) worker settings isolation, persistence and rejection checks")
    }
}
