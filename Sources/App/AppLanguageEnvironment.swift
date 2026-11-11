#if os(iOS)
import SwiftUI

private struct AppLocalizerKey: EnvironmentKey {
    static let defaultValue = AppLocalizer(language: .traditionalChinese)
}

extension EnvironmentValues {
    var appLocalizer: AppLocalizer {
        get { self[AppLocalizerKey.self] }
        set { self[AppLocalizerKey.self] = newValue }
    }
}

/// Root integration: keep the same store and all existing sessions alive.
/// This modifier never adds an identity boundary or changes an authorization.
@MainActor private struct AppLanguageModifier: ViewModifier {
    @ObservedObject var store: AppLanguageStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.appLocalizer, AppLocalizer(language: store.resolved))
            .environment(\.locale, Locale(identifier: store.resolved.rawValue))
            .onChange(of: scenePhase) { phase in
                if phase == .active { store.refreshSystemLanguages() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                store.refreshSystemLanguages()
            }
    }
}

extension View {
    @MainActor func appLanguage(_ store: AppLanguageStore) -> some View {
        modifier(AppLanguageModifier(store: store))
    }
}
#endif
