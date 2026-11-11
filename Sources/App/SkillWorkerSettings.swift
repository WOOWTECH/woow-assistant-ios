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
    @Published private(set) var errorText: AppText?
    @Published private(set) var noticeText: AppText?
    var error: String? { errorText.map { AppLocalizer(language: .traditionalChinese).text($0) } }
    var notice: String? { noticeText.map { AppLocalizer(language: .traditionalChinese).text($0) } }
    private var repository: SkillWorkerSettingsRepository?

    init() {
        do { repository = try .makeDefault(); reload() }
        catch { self.errorText = .workerLoadFailed }
    }

    init(repository: SkillWorkerSettingsRepository) {
        self.repository = repository
        reload()
    }

    func reload() {
        do {
            guard let repository else { return }
            let endpoint = try repository.endpoint()
            let loaded = try repository.worker()
            endpointDraft = endpoint?.absoluteString ?? ""; worker = loaded; errorText = nil
        } catch { worker = nil; self.errorText = .workerCredentialsFailed }
    }

    func save() {
        defer { tokenDraft = "" }
        do {
            guard let repository else { throw SkillWorkerSettingsRepository.Failure.invalidRecord }
            let cleanupFailed = try repository.save(endpoint: endpointDraft, token: tokenDraft)
            reload()
            if errorText == nil {
                noticeText = cleanupFailed ? .workerSavedCleanupFailed : .workerSaved
            }
        } catch let failure as ModelSettingsError { errorText = AppLocalizer.modelSettingsError(failure); noticeText = nil }
        catch { self.errorText = .workerInvalid; noticeText = nil }
    }

    func remove() {
        do {
            guard let repository else { throw SkillWorkerSettingsRepository.Failure.invalidRecord }
            try repository.remove(); worker = nil; endpointDraft = ""; tokenDraft = ""
            errorText = nil; noticeText = .workerRemoved
        } catch { self.errorText = .workerRemoveFailed; noticeText = nil }
    }
}
