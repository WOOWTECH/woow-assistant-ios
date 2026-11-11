import SwiftUI

@MainActor struct SkillWorkerSettingsView: View {
    @ObservedObject var settings: SkillWorkerPreferences
    @Environment(\.appLocalizer) private var localizer
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section(localizer.text(.workerSection)) {
                Text(localizer.text(.workerExplanation))
                TextField(localizer.text(.workerEndpoint), text: $settings.endpointDraft)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($editing).accessibilityIdentifier("skillWorker.endpoint")
                SecureField(localizer.text(.workerToken), text: $settings.tokenDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .focused($editing).accessibilityIdentifier("skillWorker.token")
                Button(localizer.text(.workerSave)) { editing = false; settings.save() }
                    .accessibilityIdentifier("skillWorker.save")
                Button(localizer.text(.workerRemove), role: .destructive) { editing = false; settings.remove() }
                    .accessibilityIdentifier("skillWorker.remove")
            }
            Section {
                Text(settings.worker == nil ? localizer.text(.workerLocal) : localizer.text(.workerConfigured))
                    .accessibilityIdentifier("skillWorker.status")
                Text(localizer.text(.workerPrivacy))
                if let error = settings.errorText { Text(verbatim: localizer.text(error)).foregroundStyle(.red).accessibilityIdentifier("skillWorker.error") }
                if let notice = settings.noticeText { Text(verbatim: localizer.text(notice)).accessibilityIdentifier("skillWorker.notice") }
            }
        }
        .navigationTitle(localizer.text(.workerTitle))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer(); Button(localizer.text(.keyboardDone)) { editing = false }.accessibilityIdentifier("skillWorker.keyboard.done")
            }
        }
        .onDisappear { settings.tokenDraft = "" }
    }
}
