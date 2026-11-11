import SwiftUI

@MainActor
struct MCPToolsView: View {
    @Environment(\.appLocalizer) private var localizer
    @StateObject private var session: MCPSession
    @FocusState private var isEditingEndpoint: Bool
    @FocusState private var isSearchingTools: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmRemoval = false

    init() { _session = StateObject(wrappedValue: MCPSession()) }
    init(session: MCPSession) { _session = StateObject(wrappedValue: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Persistent outside List: virtualization must not hide connection state.
            VStack(alignment: .leading, spacing: 4) {
                Text(localizer.text(.mcpTitle))
                    .font(.title2.bold())
                    .accessibilityIdentifier("tools.status")
                Text(localizer.text(session.statusMessage))
                    .font(.callout)
                    .accessibilityIdentifier("mcp.status")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        List {
            Section(localizer.text(.mcpConnectionSection)) {
                Text(localizer.text(.mcpProtocol(version: session.protocolVersion ?? localizer.text(.commonUnknown))))
                    .accessibilityIdentifier("mcp.protocol")
                if session.phase == .connected {
                    Text(session.supportsTools ? localizer.text(.mcpToolCount(count: session.toolNames.count)) : localizer.text(.mcpNoTools))
                        .accessibilityIdentifier("mcp.toolCount")
                    Text(session.supportsResources ? localizer.text(.mcpResourceCount(count: session.resourceNames.count)) : localizer.text(.mcpNoResources))
                        .accessibilityIdentifier("mcp.resourceCount")
                }
                Text(localizer.text(.mcpExplanation))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tools.explanation")
                if !session.allowsNetwork {
                    Text(localizer.text(.mcpIsolation))
                        .accessibilityIdentifier("mcp.testIsolation")
                }
                Text(session.hasStoredEndpoint ? localizer.text(.mcpStored) : localizer.text(.mcpNotStored))
                    .accessibilityIdentifier("mcp.endpointStatus")
                SecureField(localizer.text(.mcpEndpoint), text: $session.endpointDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .focused($isEditingEndpoint)
                    .submitLabel(.done)
                    .onSubmit { isEditingEndpoint = false }
                    .disabled(session.isBusy)
                    .accessibilityLabel(localizer.text(.mcpEndpointAX))
                    .accessibilityIdentifier("mcp.endpoint")
                Text(localizer.text(.mcpEndpointHelp))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(localizer.text(.mcpSave)) {
                    isEditingEndpoint = false
                    session.saveEndpoint()
                }
                .disabled(!session.canSave)
                .accessibilityIdentifier("mcp.save")
                Button(localizer.text(.mcpClearDraft)) { session.endpointDraft = "" }
                    .disabled(session.endpointDraft.isEmpty || session.isBusy)
                    .accessibilityIdentifier("mcp.clearDraft")
                if session.hasStoredEndpoint {
                    Button(localizer.text(.mcpRemoveStored), role: .destructive) { confirmRemoval = true }
                        .disabled(session.isBusy)
                        .accessibilityIdentifier("mcp.remove")
                }
            }

            Section(localizer.text(.mcpExploration)) {
                if session.isBusy {
                    ProgressView(localizer.text(session.statusMessage))
                    Button(localizer.text(.mcpCancel)) { session.cancel() }
                        .accessibilityIdentifier("mcp.cancel")
                } else {
                    Button(localizer.text(.mcpConnect)) {
                        isEditingEndpoint = false
                        session.connect()
                    }
                    .disabled(!session.canConnect)
                    .accessibilityIdentifier("mcp.connect")
                }
                if session.phase == .connected {
                    Button(localizer.text(.mcpDisconnect)) { session.disconnect() }
                        .accessibilityIdentifier("mcp.disconnect")
                }
                if let error = session.errorText {
                    Text(localizer.text(error))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("mcp.error")
                }
                if let notice = session.noticeText {
                    Text(localizer.text(notice))
                        .font(.footnote)
                        .accessibilityIdentifier("mcp.notice")
                }
            }

            if session.phase == .connected {
                Section(localizer.text(.mcpServerTools)) {
                    Text(localizer.text(.mcpSelectedCount(count: session.selectedToolNames.count)))
                        .accessibilityIdentifier("mcp.selectionCount")
                    TextField(localizer.text(.mcpSearchTools), text: $session.toolSearch)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($isSearchingTools).submitLabel(.done)
                        .onSubmit { isSearchingTools = false }
                        .accessibilityIdentifier("mcp.toolSearch")
                    ForEach(session.visibleTools, id: \.name) { tool in
                        Toggle(isOn: Binding(get: { session.selectedToolNames.contains(tool.name) },
                                             set: { session.selectTool(tool.name, enabled: $0) })) {
                            Text(verbatim: tool.name).privacySensitive()
                        }
                        .accessibilityIdentifier("mcp.enable.\(tool.name)")
                    }
                }
                Section(localizer.text(.mcpServerResources)) {
                    ForEach(Array(session.resources.enumerated()), id: \.element.uri) { index, resource in
                        Toggle(isOn: Binding(get: { session.selectedResourceURIs.contains(resource.uri) },
                                             set: { session.selectResource(resource.uri, enabled: $0) })) {
                            Text(verbatim: resource.name).privacySensitive()
                        }
                        .accessibilityIdentifier("mcp.resource.\(index)")
                    }
                }
            }

            Section(localizer.text(.mcpSkills)) {
                Text(localizer.text(.mcpSkillsLocation))
                    .accessibilityIdentifier("mcp.skillsStatus")
                Text(localizer.text(.mcpSkillsHelp))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(localizer.text(.keyboardDone)) { isEditingEndpoint = false; isSearchingTools = false }
                    .accessibilityIdentifier("mcp.dismissKeyboard")
            }
        }
        .confirmationDialog(localizer.text(.mcpRemoveQuestion), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(localizer.text(.mcpRemove), role: .destructive) { session.removeEndpoint() }
                .accessibilityIdentifier("mcp.confirmRemove")
        }
        .onDisappear {
            session.endpointDraft = ""
            if session.isBusy { session.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.endpointDraft = ""
                if session.isBusy || session.phase == .connected { session.disconnect() }
            }
        }
    }
}
