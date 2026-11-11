import Foundation

/// Only the composition root or settings entry creates this store. UI test
/// namespaces never fall back to the user's preferences after invalid input.
enum AppLanguagePreferences {
    enum ConfigurationError: Error { case invalidTestNamespace }
    static let productionSuite = "io.woowtech.assistant.interface-language.v1"

    static func suiteName(arguments: [String], debug: Bool) throws -> String {
        guard debug else { return productionSuite }
        let modes = [("-UITestMode", "-UITestNamespace"), ("-LiveModelUITest", "-LiveModelUITestNamespace")]
        let hasTestArguments = arguments.contains { $0.hasPrefix("-UITest") || $0.hasPrefix("-Live") }
        guard hasTestArguments else { return productionSuite }
        let selected = modes.filter { arguments.contains($0.0) }
        guard selected.count == 1, let mode = selected.first,
              arguments.filter({ $0 == mode.0 }).count == 1,
              arguments.filter({ $0 == mode.1 }).count == 1,
              !modes.contains(where: { $0.1 != mode.1 && arguments.contains($0.1) }),
              let index = arguments.firstIndex(of: mode.1), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]) else {
            throw ConfigurationError.invalidTestNamespace
        }
        return productionSuite + ".test." + namespace.uuidString
    }
}

extension AppLanguageStore {
    static func applicationPreferences(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppLanguageStore {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        guard let suite = try? AppLanguagePreferences.suiteName(arguments: arguments, debug: debug),
              let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Language preferences require a valid isolated namespace")
        }
        return AppLanguageStore(defaults: defaults)
    }
}
