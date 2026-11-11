#if os(iOS)
import AssistantSkills
import SwiftUI

/// Parent integration:
/// @StateObject var preferences = SelfConfigurationStore(defaults: isolatedDefaults)
/// root.preferredColorScheme(preferences.preferredColorScheme)
/// SelfConfigurationView(store: preferences, modelAccess: { try session.modelAccess() })
@MainActor struct SelfConfigurationView: View {
    @ObservedObject var store: SelfConfigurationStore
    let modelAccess: () throws -> ModelAccess
    @StateObject private var session = SelfConfigurationSession()
    @StateObject private var languages: AppLanguageStore
    @State private var languageSaveFailed = false
    @State private var request = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editing: Bool

    init(store: SelfConfigurationStore, modelAccess: @escaping () throws -> ModelAccess,
         languages: AppLanguageStore? = nil) {
        self.store = store
        self.modelAccess = modelAccess
        _languages = StateObject(wrappedValue: languages ?? AppLanguageStore.applicationPreferences())
    }

    private var localizer: AppLocalizer { AppLocalizer(language: languages.resolved) }

    var body: some View {
        Form {
            Section(localizer.text(.appearanceTitle)) {
                Picker(localizer.text(.appearanceCurrent), selection: Binding(get: { store.appearance }, set: {
                    session.cancel(); store.setAppearanceFromUser($0)
                })) {
                    ForEach(SelfConfigurationAppearance.allCases, id: \.self) { value in
                        Text(verbatim: localizer.appearanceName(value)).tag(value)
                    }
                }.accessibilityIdentifier("selfConfiguration.appearance")
                Text(verbatim: localizer.text(colorScheme == .dark ? .appearanceAppliedDark : .appearanceAppliedLight))
                    .accessibilityIdentifier("selfConfiguration.appliedAppearance")
                Text(verbatim: localizer.text(.appearanceExplanation))
                    .font(.footnote)
            }
            Section(localizer.text(.configurationPermissionTitle)) {
                Toggle(localizer.text(.configurationPermission), isOn: Binding(get: { store.allowSelfConfiguration }, set: {
                    session.cancel(); store.setPermissionFromUser($0)
                })).accessibilityIdentifier("selfConfiguration.permission")
                Text(verbatim: localizer.text(.configurationPermissionExplanation))
                    .font(.footnote)
            }
            if store.allowSelfConfiguration {
                Section(localizer.text(.configurationRequestTitle)) {
                    Text(verbatim: localizer.text(.configurationRequestExplanation))
                        .font(.footnote)
                    TextEditor(text: $request).frame(minHeight: 100).focused($editing)
                        .autocorrectionDisabled().accessibilityLabel(Text(verbatim: localizer.text(.configurationRequestLabel)))
                        .accessibilityIdentifier("selfConfiguration.request")
                    if let question = session.question {
                        Text(verbatim: question).accessibilityIdentifier("selfConfiguration.question")
                    }
                    if session.running {
                        Button(localizer.text(.configurationCancel)) { session.cancel() }
                            .accessibilityIdentifier("selfConfiguration.cancel")
                    } else {
                        Button(localizer.text(.configurationStart)) {
                            editing = false
                            session.start(request: request, store: store, modelAccess: modelAccess)
                        }
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.utf8.count > 2000)
                        .accessibilityIdentifier("selfConfiguration.start")
                    }
                }
            }
            Section(localizer.text(.configurationResult)) {
                Text(verbatim: session.presentation.text(using: localizer)).accessibilityIdentifier("selfConfiguration.status")
                if let error = session.errorText {
                    Text(verbatim: localizer.text(error)).foregroundStyle(.red).accessibilityIdentifier("selfConfiguration.error")
                }
                if !session.stepEvents.isEmpty {
                    Text(verbatim: localizer.text(.configurationStepCount(count: session.stepEvents.count)))
                        .accessibilityIdentifier("selfConfiguration.stepCount")
                }
                ForEach(Array(session.stepEvents.enumerated()), id: \.offset) { index, step in
                    Text(verbatim: localizer.configurationStep(step)).font(.caption).accessibilityIdentifier("selfConfiguration.step.\(index)")
                }
            }
            Section(localizer.text(.languageTitle)) {
                Picker(localizer.text(.languageTitle), selection: Binding(get: { languages.language }, set: {
                    languageSaveFailed = !languages.setFromUser($0)
                })) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Text(verbatim: localizer.languageName(choice)).tag(choice)
                    }
                }.accessibilityIdentifier("settings.language")
                Text(verbatim: localizer.text(.languageResolved(name: localizer.resolvedLanguageName)))
                    .accessibilityIdentifier("settings.language.resolved")
                Text(verbatim: localizer.text(.languageExplanation)).font(.footnote)
                Text(verbatim: localizer.text(.languagePartialNotice)).font(.footnote)
                    .accessibilityIdentifier("settings.language.coverage")
                if languageSaveFailed {
                    Text(verbatim: localizer.text(.languageSaveFailed)).foregroundStyle(.red)
                        .accessibilityIdentifier("settings.language.error")
                }
            }
        }
        .appLanguage(languages)
        .navigationTitle(localizer.text(.configurationTitle))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(localizer.text(.keyboardDone)) { editing = false }
                    .accessibilityIdentifier("selfConfiguration.keyboard.done")
            }
        }
        .onChange(of: store.allowSelfConfiguration) { _ in session.cancel() }
        .onDisappear { session.cancel(showNotice: false) }
    }
}
#endif
