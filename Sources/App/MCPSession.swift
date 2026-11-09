import AssistantMCP
import Combine
import Foundation

// The UI deliberately has no tool invocation or resource-content API.
protocol MCPDiscovering: Sendable {
    func initialize() async throws -> MCPServerInfo
    func listTools() async throws -> [MCPTool]
    func listResources() async throws -> [MCPResource]
    func cancel() async
}

extension MCPClient: MCPDiscovering {}

@MainActor
final class MCPSession: ObservableObject {
    enum Phase: Equatable {
        case notConfigured, saved, connecting, discovering, connected, disconnected, cancelled, failed
    }

    @Published var endpointDraft = ""
    @Published private(set) var hasStoredEndpoint = false
    @Published private(set) var phase: Phase = .notConfigured
    @Published private(set) var protocolVersion: String?
    @Published private(set) var toolNames: [String] = []
    @Published private(set) var resourceNames: [String] = []
    @Published private(set) var supportsTools = false
    @Published private(set) var supportsResources = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    let allowsNetwork: Bool
    private let repository: (any MCPEndpointStoring)?
    private let clientFactory: @Sendable (URL) -> any MCPDiscovering
    private var client: (any MCPDiscovering)?
    private var request: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var requestID: UUID?

    init() {
        allowsNetwork = MCPSettingsStore.networkAllowed()
        clientFactory = { MCPClient(endpoint: $0) }
        let store: MCPSettingsStore
        do {
            store = try MCPSettingsStore.makeDefault()
        } catch {
            repository = nil
            errorMessage = Self.settingsMessage(error)
            phase = .failed
            return
        }
        repository = store
        do {
            hasStoredEndpoint = try store.load() != nil
            phase = hasStoredEndpoint ? .saved : .notConfigured
        } catch {
            errorMessage = Self.settingsMessage(error)
            phase = .failed
        }
        // Never load the credential into a published property or start networking here.
    }

    init(repository: any MCPEndpointStoring, allowsNetwork: Bool = true,
         clientFactory: @escaping @Sendable (URL) -> any MCPDiscovering = { MCPClient(endpoint: $0) }) {
        self.repository = repository
        self.allowsNetwork = allowsNetwork
        self.clientFactory = clientFactory
        do {
            hasStoredEndpoint = try repository.load() != nil
            phase = hasStoredEndpoint ? .saved : .notConfigured
        } catch {
            errorMessage = Self.settingsMessage(error)
            phase = .failed
        }
    }

    deinit { request?.cancel(); deadline?.cancel() }

    var isBusy: Bool { phase == .connecting || phase == .discovering }
    var canSave: Bool { repository != nil && !isBusy && !endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canConnect: Bool {
        hasStoredEndpoint && !isBusy && phase != .connected
            && endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && allowsNetwork
    }
    var statusText: String {
        switch phase {
        case .notConfigured: return "尚未設定 MCP"
        case .saved: return "端點已儲存，尚未驗證連線"
        case .connecting: return "正在建立 MCP 工作階段…"
        case .discovering: return "正在擷取工具與資源目錄…"
        case .connected: return "已連線，目錄擷取完成"
        case .disconnected: return "已中斷本機連線"
        case .cancelled: return "已取消等待"
        case .failed: return "MCP 設定或連線未完成"
        }
    }

    func saveEndpoint() {
        guard !isBusy, let repository else { return }
        errorMessage = nil
        notice = nil
        do {
            try repository.save(endpoint: endpointDraft)
            stopWork()
            clearCatalog()
            endpointDraft = ""
            hasStoredEndpoint = true
            phase = .saved
            notice = "端點已存入此裝置的 Keychain；尚未送出連線請求。"
        } catch { errorMessage = Self.settingsMessage(error) }
    }

    func removeEndpoint() {
        guard !isBusy, let repository else { return }
        errorMessage = nil
        notice = nil
        do {
            try repository.remove()
            stopWork()
            clearCatalog()
            endpointDraft = ""
            hasStoredEndpoint = false
            phase = .notConfigured
            notice = "已移除此 App 的 MCP 端點。"
        } catch { errorMessage = Self.settingsMessage(error) }
    }

    func connect() {
        guard canConnect, let repository else { return }
        errorMessage = nil
        notice = nil
        clearCatalog()
        let endpoint: URL
        do {
            guard let stored = try repository.load() else {
                hasStoredEndpoint = false
                phase = .notConfigured
                return
            }
            endpoint = stored
        } catch {
            phase = .failed
            errorMessage = Self.settingsMessage(error)
            return
        }
        let connection = clientFactory(endpoint)
        let id = UUID()
        requestID = id
        client = connection
        phase = .connecting
        request = Task { [weak self] in
            do {
                let info = try await connection.initialize()
                try Task.checkCancellation()
                guard self?.requestID == id else { return }
                self?.phase = .discovering
                // The native actor serializes operations, so do not issue these concurrently.
                let tools = info.capabilities.contains("tools") ? try await connection.listTools() : []
                try Task.checkCancellation()
                let resources = info.capabilities.contains("resources") ? try await connection.listResources() : []
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.protocolVersion = info.protocolVersion
                self.supportsTools = info.capabilities.contains("tools")
                self.supportsResources = info.capabilities.contains("resources")
                self.toolNames = tools.map { Self.displayName($0.name, endpoint: endpoint) }
                self.resourceNames = resources.map { Self.displayName($0.name, endpoint: endpoint) }
                self.finish(id: id)
                self.phase = .connected
                self.notice = "僅完成握手與目錄探索，未執行工具或讀取資源內容；不代表服務持續在線。"
            } catch {
                guard let self, self.requestID == id else { return }
                self.stopWork()
                self.clearCatalog()
                self.phase = .failed
                // Never interpolate server errors, names, resource URIs, or endpoint URLs.
                self.errorMessage = "MCP 連線或目錄擷取失敗。請檢查端點、網路及伺服器的 Streamable HTTP 支援；不會自動重試。"
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.stopWork()
            self.clearCatalog()
            self.phase = .failed
            self.errorMessage = "探索超過 90 秒，已停止本機等待；伺服器可能已收到目錄請求。"
        }
    }

    func cancel() {
        guard isBusy else { return }
        stopWork()
        clearCatalog()
        phase = .cancelled
        errorMessage = nil
        notice = "已取消本機等待；伺服器可能已收到目錄請求。"
    }

    func disconnect() {
        stopWork()
        clearCatalog()
        phase = hasStoredEndpoint ? .disconnected : .notConfigured
        errorMessage = nil
        notice = "已停止本機工作並清除目錄；端點設定保留。未要求伺服器撤銷憑證或刪除遠端工作階段。"
    }

    private func finish(id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        request = nil
        deadline?.cancel()
        deadline = nil
    }

    private func stopWork() {
        requestID = nil // Invalidate before cancellation, so late replies cannot restore the UI.
        request?.cancel()
        request = nil
        deadline?.cancel()
        deadline = nil
        if let previous = client { Task { await previous.cancel() } }
        client = nil
    }

    private func clearCatalog() {
        protocolVersion = nil
        toolNames = []
        resourceNames = []
        supportsTools = false
        supportsResources = false
    }

    private static func settingsMessage(_ error: Error) -> String {
        (error as? MCPSettingsError)?.errorDescription ?? "MCP 設定存取失敗；不會顯示端點或原始錯誤內容。"
    }

    private static func displayName(_ name: String, endpoint: URL) -> String {
        let redacted = name.replacingOccurrences(of: endpoint.absoluteString, with: "（端點已隱藏）")
        let scalars = redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let title = String(String.UnicodeScalarView(scalars)).prefix(160)
        return title.isEmpty ? "（未提供可顯示的名稱）" : String(title)
    }
}
