import SwiftUI

@MainActor
struct MCPToolsView: View {
    @StateObject private var session: MCPSession
    @FocusState private var isEditingEndpoint: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmRemoval = false

    init() { _session = StateObject(wrappedValue: MCPSession()) }
    init(session: MCPSession) { _session = StateObject(wrappedValue: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Persistent outside List: virtualization must not hide connection state.
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP 與 Skills")
                    .font(.title2.bold())
                    .accessibilityIdentifier("tools.status")
                Text(session.statusText)
                    .font(.callout)
                    .accessibilityIdentifier("mcp.status")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        List {
            Section("MCP 連線與目錄") {
                Text("協定版本：\(session.protocolVersion ?? "尚未取得")")
                    .accessibilityIdentifier("mcp.protocol")
                if session.phase == .connected {
                    Text(session.supportsTools ? "工具：\(session.toolNames.count) 個" : "伺服器未宣告工具能力")
                        .accessibilityIdentifier("mcp.toolCount")
                    Text(session.supportsResources ? "資源：\(session.resourceNames.count) 個" : "伺服器未宣告資源能力")
                        .accessibilityIdentifier("mcp.resourceCount")
                }
                Text("僅支援 HTTPS Streamable HTTP。本版只探索目錄，不執行工具、不讀取資源內容，也不會自動連線。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tools.explanation")
                if !session.allowsNetwork {
                    Text("UI 測試隔離模式：不會發送 MCP 網路請求。")
                        .accessibilityIdentifier("mcp.testIsolation")
                }
                Text(session.hasStoredEndpoint ? "端點已安全儲存；不顯示網址。" : "尚未儲存端點。")
                    .accessibilityIdentifier("mcp.endpointStatus")
                SecureField("完整 HTTPS MCP 端點", text: $session.endpointDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .focused($isEditingEndpoint)
                    .submitLabel(.done)
                    .onSubmit { isEditingEndpoint = false }
                    .disabled(session.isBusy)
                    .accessibilityLabel("MCP 私密端點")
                    .accessibilityIdentifier("mcp.endpoint")
                Text("Webhook URL 等同憑證，完整網址僅儲存於此裝置解鎖時可讀取的 Keychain，不透過 iCloud 同步。輸入新端點後，請先儲存或清除草稿再連線。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("儲存端點") {
                    isEditingEndpoint = false
                    session.saveEndpoint()
                }
                .disabled(!session.canSave)
                .accessibilityIdentifier("mcp.save")
                Button("清除輸入") { session.endpointDraft = "" }
                    .disabled(session.endpointDraft.isEmpty || session.isBusy)
                    .accessibilityIdentifier("mcp.clearDraft")
                if session.hasStoredEndpoint {
                    Button("移除已儲存端點", role: .destructive) { confirmRemoval = true }
                        .disabled(session.isBusy)
                        .accessibilityIdentifier("mcp.remove")
                }
            }

            Section("探索狀態") {
                if session.isBusy {
                    ProgressView(session.statusText)
                    Button("取消等待") { session.cancel() }
                        .accessibilityIdentifier("mcp.cancel")
                } else {
                    Button("連線並探索目錄") {
                        isEditingEndpoint = false
                        session.connect()
                    }
                    .disabled(!session.canConnect)
                    .accessibilityIdentifier("mcp.connect")
                }
                if session.phase == .connected {
                    Button("中斷連線") { session.disconnect() }
                        .accessibilityIdentifier("mcp.disconnect")
                }
                if let error = session.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("mcp.error")
                }
                if let notice = session.notice {
                    Text(notice)
                        .font(.footnote)
                        .accessibilityIdentifier("mcp.notice")
                }
            }

            if session.phase == .connected {
                Section("伺服器工具") {
                    ForEach(Array(session.toolNames.enumerated()), id: \.offset) { index, name in
                        Text(verbatim: name)
                            .privacySensitive()
                            .accessibilityIdentifier("mcp.tool.\(index)")
                    }
                }
                Section("伺服器資源") {
                    ForEach(Array(session.resourceNames.enumerated()), id: \.offset) { index, name in
                        Text(verbatim: name)
                            .privacySensitive()
                            .accessibilityIdentifier("mcp.resource.\(index)")
                    }
                }
            }

            Section("Skills") {
                Text("尚未實作")
                    .accessibilityIdentifier("mcp.skillsStatus")
                Text("尚不支援匯入、安裝或執行 Skills；MCP 目錄探索不代表 Skills 已可使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isEditingEndpoint = false }
                    .accessibilityIdentifier("mcp.dismissKeyboard")
            }
        }
        .confirmationDialog("移除此裝置儲存的 MCP 端點？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移除端點", role: .destructive) { session.removeEndpoint() }
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
