import AssistantSkills
import Combine
import Foundation

@MainActor final class SelfConfigurationSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var presentation: SelfConfigurationMessage = .idle
    @Published private(set) var question: String?
    @Published private(set) var errorText: AppText?
    @Published private(set) var stepEvents: [SelfConfigurationEvent] = []

    // Compatibility for existing native harnesses; views use typed state.
    var message: String { presentation.text(using: AppLocalizer(language: .traditionalChinese)) }
    var error: String? { errorText.map { AppLocalizer(language: .traditionalChinese).text($0) } }
    var steps: [String] { stepEvents.map { AppLocalizer(language: .traditionalChinese).configurationStep($0) } }
    private var task: Task<Void, Never>?
    private var runtime: SelfConfigurationRuntime?
    private var operationID: UUID?

    func start(request: String, store: SelfConfigurationStore, modelAccess: () throws -> ModelAccess) {
        cancel(showNotice: false)
        question = nil; errorText = nil; stepEvents = []
        do {
            // Refuse before resolving credentials or starting a model request.
            guard let original = try BundledSkillCatalog.bundled().entry(id: "configure-mika")?.original else {
                throw SkillCatalogError.notFound
            }
            let reference = "來源：\(original.path)\n版本：\(BundledSkillCatalog.pinnedCommit)\nSHA-256：\(original.sha256)\n\n" + original.content
            let runtime = try SelfConfigurationRuntime(request: request, store: store, sourceReference: reference)
            let access = try modelAccess()
            self.runtime = runtime
            let id = UUID()
            operationID = id
            running = true
            presentation = .running
            task = Task { [weak self] in
                do {
                    let outcome = try await runtime.run(client: access.client, configuration: access.configuration,
                        apiKey: access.key, onEvent: { [weak self] event in
                            guard let self, self.operationID == id else { return }
                            self.stepEvents.append(event)
                        })
                    guard let self, self.operationID == id, !Task.isCancelled else { return }
                    switch outcome {
                    case .changed(let receipt):
                        self.presentation = .changed(receipt.appearance)
                    case .needsClarification(let question):
                        self.question = question
                        self.presentation = .clarification
                    case .unchanged: self.presentation = .unchanged
                    }
                    self.finish()
                } catch {
                    guard let self, self.operationID == id else { return }
                    self.errorText = (error as? SelfConfigurationError).map { AppLocalizer(language: .traditionalChinese).configurationError($0) } ?? .configurationErrorModel
                    self.presentation = .stopped
                    self.finish()
                }
            }
        } catch {
            self.errorText = (error as? SelfConfigurationError).map { AppLocalizer(language: .traditionalChinese).configurationError($0) } ?? .configurationNeedsModel
            presentation = .notStarted
        }
    }

    func cancel(showNotice: Bool = true) {
        let wasRunning = running
        operationID = nil
        runtime?.cancel(); task?.cancel()
        runtime = nil; task = nil; running = false
        if showNotice && wasRunning { presentation = .cancelled }
    }

    private func finish() {
        operationID = nil; runtime = nil; task = nil; running = false
    }
}
