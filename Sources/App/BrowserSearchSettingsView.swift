import AssistantBrowser
import SwiftUI

@MainActor
struct BrowserSearchSettingsView: View {
    @Environment(\.appLocalizer) private var localizer
    @ObservedObject var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    private enum Field { case name, template }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section(localizer.text(.searchTitle)) {
                    ForEach(workspace.library.searchSettings.all) { engine in
                        HStack {
                            Button { workspace.selectSearchEngine(engine.id) } label: {
                                HStack {
                                    Text(engine.name)
                                    Spacer()
                                    if workspace.library.searchSettings.selectedID == engine.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }.accessibilityIdentifier("browser.searchEngine.select.\(engine.id)")
                                .accessibilityValue(workspace.library.searchSettings.selectedID == engine.id ? localizer.text(.commonSelected) : localizer.text(.commonUnselected))
                            if engine.id.hasPrefix("custom:") {
                                Button(localizer.text(.commonDelete), role: .destructive) { workspace.removeSearchEngine(engine.id) }
                                    .accessibilityLabel(localizer.text(.commonDeleteName(name: engine.name)))
                                    .accessibilityIdentifier("browser.searchEngine.remove.\(engine.id)")
                            }
                        }.buttonStyle(.borderless)
                    }
                }
                Section(localizer.text(.searchCustom)) {
                    TextField(localizer.text(.commonName), text: $name).autocorrectionDisabled()
                        .focused($focusedField, equals: .name).submitLabel(.next)
                        .onSubmit { focusedField = .template }
                        .accessibilityIdentifier("browser.searchEngine.name")
                    TextField(localizer.text(.searchTemplate), text: $template)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .focused($focusedField, equals: .template).submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("browser.searchEngine.template")
                    Text(localizer.text(.searchHelp))
                        .font(.caption)
                    Button(localizer.text(.searchAdd)) {
                        focusedField = nil
                        if workspace.addSearchEngine(name: name, template: template) { name = ""; template = "" }
                    }.accessibilityIdentifier("browser.searchEngine.add")
                }
                if let error = workspace.errorText {
                    Text(localizer.text(error)).foregroundStyle(.red).accessibilityIdentifier("browser.searchEngine.error")
                }
                Text(localizer.text(.searchChanges))
                    .font(.caption)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(!workspace.available || workspace.isClearingWebsiteData)
            .navigationTitle(localizer.text(.searchTitle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("browser.searchEngine.close")
                }
            }
        }
    }
}
