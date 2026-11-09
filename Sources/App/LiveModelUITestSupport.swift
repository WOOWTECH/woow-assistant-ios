#if DEBUG
import Foundation

// Private-runner UI test entry point. Never enabled in Release or by -UITestMode.
// -LiveModelUITest -LiveModelUITestNamespace <UUID>
// Add -LiveModelUITestCleanup to remove only this namespace, without reading credentials.
// Reads only WOOW_LIVE_BASE_URL, WOOW_LIVE_MODEL and WOOW_LIVE_API_KEY at bootstrap.
// No credentials go through SwiftUI fields, console output, or test attachments.
enum LiveModelUITestSupport {
    static func repository(arguments: [String]) -> ModelSettingsRepository {
        guard let flag = arguments.firstIndex(of: "-LiveModelUITestNamespace"),
              arguments.indices.contains(flag + 1),
              let namespace = UUID(uuidString: arguments[flag + 1]) else {
            preconditionFailure("Live UI tests require an isolated namespace UUID")
        }
        let service = "io.woowtech.assistant.liveuitest.\(namespace.uuidString)"
        guard let defaults = UserDefaults(suiteName: service) else {
            preconditionFailure("Cannot create isolated live UI test defaults")
        }
        return ModelSettingsRepository(defaults: defaults, credentials: KeychainModelCredentials(service: service))
    }

    static func bootstrap(_ repository: ModelSettingsRepository, environment: [String: String]) throws {
        // Clear only this invocation's isolated service, before applying a new test config.
        try repository.remove()
        guard let baseURL = environment["WOOW_LIVE_BASE_URL"],
              let model = environment["WOOW_LIVE_MODEL"],
              let key = environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            throw ModelSettingsError.missingKey
        }
        _ = try repository.save(baseURL: baseURL, model: model, newKey: key)
    }
}
#endif
