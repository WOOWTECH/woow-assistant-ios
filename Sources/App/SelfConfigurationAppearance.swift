import AssistantSkills
import SwiftUI

extension SelfConfigurationStore {
    static func applicationPreferences(arguments: [String] = ProcessInfo.processInfo.arguments) -> SelfConfigurationStore {
        var suite = "io.woowtech.assistant.appearance.v1"
        #if DEBUG
        let modes = [("-UITestMode", "-UITestNamespace"), ("-LiveModelUITest", "-LiveModelUITestNamespace")]
        let selected = modes.filter { arguments.contains($0.0) }
        if !selected.isEmpty || arguments.contains(where: { $0.hasPrefix("-UITest") || $0.hasPrefix("-Live") }) {
            guard selected.count == 1, let mode = selected.first,
                  arguments.filter({ $0 == mode.0 }).count == 1,
                  arguments.filter({ $0 == mode.1 }).count == 1,
                  let index = arguments.firstIndex(of: mode.1), arguments.indices.contains(index + 1),
                  let namespace = UUID(uuidString: arguments[index + 1]) else {
                preconditionFailure("Appearance UI tests require an isolated namespace")
            }
            suite += ".test." + namespace.uuidString
        }
        #endif
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Appearance defaults unavailable") }
        return SelfConfigurationStore(defaults: defaults)
    }

    /// Attach to the root using the SAME observed store supplied to the settings
    /// view. A nil override restores the current system appearance immediately.
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
