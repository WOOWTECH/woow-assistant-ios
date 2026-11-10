import AssistantSkills
import Combine
import Foundation

/// Separate defaults and Keychain service: a PDF gateway can never inherit the
/// chat model's credential. Configuration does not dispatch a request or upload.
final class SkillWorkerSettingsRepository {
    private let storage: ModelSettingsRepository
    private static let kind = "mika-extract-pdf-v1"
    enum Failure: Error { case invalidNamespace, invalidRecord }

    init(defaults: UserDefaults, credentials: any ModelCredentialStoring) {
        storage = ModelSettingsRepository(defaults: defaults, credentials: credentials)
    }

    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> SkillWorkerSettingsRepository {
        var service = "io.woowtech.assistant.skillworker.v1"
        #if DEBUG
        let modes = [("-UITestMode", "-UITestNamespace"), ("-LiveModelUITest", "-LiveModelUITestNamespace")]
        let selected = modes.filter { arguments.contains($0.0) }
        if !selected.isEmpty || arguments.contains(where: { $0.hasPrefix("-Live") || $0.hasPrefix("-UITest") }) {
            guard selected.count == 1, let mode = selected.first,
                  arguments.filter({ $0 == mode.0 }).count == 1,
                  arguments.filter({ $0 == mode.1 }).count == 1,
                  let index = arguments.firstIndex(of: mode.1), arguments.indices.contains(index + 1),
                  let namespace = UUID(uuidString: arguments[index + 1]) else { throw Failure.invalidNamespace }
            service += ".test." + namespace.uuidString
        }
        #endif
        guard let defaults = UserDefaults(suiteName: service) else { throw Failure.invalidRecord }
        return SkillWorkerSettingsRepository(defaults: defaults, credentials: KeychainModelCredentials(service: service))
    }

    func endpoint() throws -> URL? {
        guard let record = try storage.load() else { return nil }
        guard record.model == Self.kind else { throw Failure.invalidRecord }
        return record.baseURL
    }

    func worker() throws -> SkillExecutionHTTPWorker? {
        guard let record = try storage.load() else { return nil }
        guard record.model == Self.kind else { throw Failure.invalidRecord }
        return try SkillExecutionHTTPWorker(endpoint: record.baseURL, authorizationBearer: storage.key(for: record))
    }

    @discardableResult func save(endpoint: String, token: String) throws -> Bool {
        let configuration = try ModelSettingsRepository.validate(baseURL: endpoint, model: Self.kind)
        // Validate the header before touching storage. A blank key uses only a
        // prior credential at the same origin; ModelSettingsRepository enforces it.
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { _ = try SkillExecutionHTTPWorker(endpoint: configuration.baseURL, authorizationBearer: token) }
        return try storage.save(baseURL: endpoint, model: Self.kind, newKey: token).cleanupFailed
    }

    func remove() throws { try storage.remove() }
}

@MainActor final class SkillWorkerPreferences: ObservableObject {
    @Published var endpointDraft = ""
    @Published var tokenDraft = ""
    @Published private(set) var worker: SkillExecutionHTTPWorker?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var repository: SkillWorkerSettingsRepository?

    init() {
        do { repository = try .makeDefault(); reload() }
        catch { self.error = "腳本服務設定無法讀取，原資料保留。" }
    }

    func reload() {
        do {
            guard let repository else { return }
            let endpoint = try repository.endpoint()
            let loaded = try repository.worker()
            endpointDraft = endpoint?.absoluteString ?? ""; worker = loaded; error = nil
        } catch { worker = nil; self.error = "腳本服務設定或金鑰無法讀取，請重新設定或解鎖後再試。" }
    }

    func save() {
        defer { tokenDraft = "" }
        do {
            guard let repository else { throw SkillWorkerSettingsRepository.Failure.invalidRecord }
            let cleanupFailed = try repository.save(endpoint: endpointDraft, token: tokenDraft)
            reload()
            if error == nil {
                notice = cleanupFailed ? "設定已儲存，舊金鑰未能移除；請稍後重試移除設定。"
                    : "設定已儲存；尚未連線或上傳文件。"
            }
        } catch let failure as ModelSettingsError { error = failure.localizedDescription; notice = nil }
        catch { self.error = "服務網址或金鑰無效，設定未變更。"; notice = nil }
    }

    func remove() {
        do {
            guard let repository else { throw SkillWorkerSettingsRepository.Failure.invalidRecord }
            try repository.remove(); worker = nil; endpointDraft = ""; tokenDraft = ""
            error = nil; notice = "已移除腳本服務設定與金鑰。"
        } catch { self.error = "無法移除腳本服務設定與金鑰，請解鎖後重試。"; notice = nil }
    }
}
