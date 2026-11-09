import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import Combine
import Foundation

private struct LearningSnapshot: Codable {
    let version: Int
    let memory: MemoryState
    let skills: SkillsState
    init(memory: MemoryState = .init(), skills: SkillsState = .init()) {
        version = 1; self.memory = memory; self.skills = skills
    }
}

@MainActor
final class LearningStore: ObservableObject {
    @Published private(set) var memory = MemoryState()
    @Published private(set) var skills = SkillsState()
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var isLearning = false
    @Published private(set) var available = false
    private var vault: EncryptedLearningFile?
    private var extraction: Task<Void, Never>?
    private var extractionID: UUID?
    private(set) var generation = UUID()

    init() {
        do {
            let location = try Self.location()
            let file = EncryptedLearningFile(url: location.url,
                keys: LearningKeychainStore(service: location.service))
            vault = file
            if location.reset {
                _ = try file.save(LearningSnapshot(), rotateKey: true)
            }
            reload()
        } catch {
            self.error = "記憶資料暫時無法讀取，原檔保留且不會被覆寫。請解鎖後重試。"
        }
    }

    func reload() {
        cancelLearning()
        do {
            guard let vault else { throw LearningFileError.unavailable }
            let snapshot = try vault.load(LearningSnapshot.self) ?? LearningSnapshot()
            guard snapshot.version == 1 else { throw LearningFileError.invalidData }
            memory = snapshot.memory; skills = snapshot.skills
            available = true; error = nil; notes = []
        } catch {
            available = false
            self.error = "記憶資料暫時無法讀取，原檔保留且不會被覆寫。請解鎖後重試。"
        }
    }

    @discardableResult
    func updatePreferences(_ change: (inout MemoryPreferences) -> Void) -> Bool {
        mutateMemory { state in
            var preferences = state.preferences
            change(&preferences)
            state.setPreferences(preferences)
        }
    }

    @discardableResult
    func mutateMemory(_ change: (inout MemoryState) throws -> Void) -> Bool {
        cancelLearning()
        do {
            var next = memory
            try change(&next)
            try persist(memory: next, skills: skills)
            memory = next
            notes = notes.filter { note in memory.memories.contains { $0.id == note.memoryID } }
            error = nil; notice = nil
            return true
        } catch { self.error = Self.message(error); return false }
    }

    @discardableResult
    func mutateSkills(_ change: (inout SkillsState) throws -> Void) -> Bool {
        cancelLearning()
        do {
            var next = skills
            try change(&next)
            try persist(memory: memory, skills: next)
            skills = next; error = nil; notice = nil
            return true
        } catch { self.error = Self.message(error); return false }
    }

    /// Call only after the view has obtained BOTH clear-all confirmations.
    @discardableResult
    func clearAll() -> Bool {
        cancelLearning()
        do {
            guard let vault else { throw LearningFileError.unavailable }
            let nextMemory = MemoryState(preferences: memory.preferences)
            let nextSkills = SkillsState()
            let retiredKeysRemoved = try vault.save(LearningSnapshot(memory: nextMemory, skills: nextSkills), rotateKey: true)
            memory = nextMemory; skills = nextSkills; notes = []; available = true; error = nil
            notice = retiredKeysRemoved
                ? "已清除記憶、技能與草稿，並更新加密金鑰；模型和 MCP 設定保留。"
                : "資料已清除並更新加密金鑰，但舊金鑰清理未完成；請解鎖後再次執行清除。"
            return true
        } catch { self.error = Self.message(error); return false }
    }

    func undo(_ note: MemoryNote) {
        guard let token = note.undoToken else { return }
        let success = mutateMemory { state in
            guard try state.undo(token: token) else { throw MemoryError.stalePlan }
        }
        if success { notes.removeAll { $0.undoToken == token } }
    }

    func noteText(_ note: MemoryNote) -> String {
        guard let item = memory.memories.first(where: { $0.id == note.memoryID }) else {
            return note.kind == .forgot ? "已忘掉一條記憶" : "這條記憶已刪除"
        }
        switch note.kind {
        case .added: return "記住了：\(item.content)"
        case .updated: return "更新了：\(item.content)"
        case .forgot: return "已忘掉一條記憶"
        case .pending: return "待你確認做法：\(item.content)"
        }
    }

    func dismissNotice() { error = nil; notice = nil }

    func contextMessages(for prompt: String) -> [ModelMessage] {
        guard available else { return [] }
        let context = memory.context(goal: prompt)
        var messages = context.message.map { [$0] } ?? []
        // Only text guidance is available in this release. MCP catalog discovery
        // does not grant model-controlled tool execution to imported skills.
        // Mika TaskRun builds the personal-skill catalog independently of useMemory;
        // the master memory switch does NOT disable already approved skills.
        let references = skills.instructionContext(query: prompt, availableToolNames: [])
        if !references.text.isEmpty { messages.append(ModelMessage(role: "user", content: references.text)) }
        if !context.usedIDs.isEmpty {
            do {
                var next = memory
                try next.markUsed(context.usedIDs)
                try persist(memory: next, skills: skills)
                memory = next
            } catch { self.error = "已讀取記憶，但使用次數未能儲存；原記憶保留。" }
        }
        return messages
    }

    func rememberAfterReply(utterance: String, conversationID: String,
                            expectedGeneration: UUID, client: any ChatModelClient,
                            configuration: ModelConfiguration, apiKey: String) {
        // A user may clear/edit data while the MAIN reply is still in flight,
        // before extraction even exists. Its old utterance cannot repopulate data.
        guard generation == expectedGeneration else { return }
        cancelLearning()
        guard available, memory.preferences.useMemory, memory.preferences.autoRemember else { return }
        let snapshot = memory
        let input = MemoryExtractionInput(utterances: [utterance], conversationID: conversationID)
        let id = UUID()
        extractionID = id; isLearning = true; notice = nil
        extraction = Task { [weak self] in
            do {
                let plan = try await MemoryExtractor(client: client).extract(input: input, state: snapshot,
                    configuration: configuration, apiKey: apiKey)
                try Task.checkCancellation()
                guard let self, self.extractionID == id else { return }
                if plan.operationCount > 0 {
                    var next = self.memory
                    let notes = try next.apply(plan: plan)
                    try self.persist(memory: next, skills: self.skills)
                    self.memory = next; self.notes = notes; self.error = nil
                }
                self.extractionID = nil; self.extraction = nil; self.isLearning = false
            } catch {
                guard let self, self.extractionID == id else { return }
                self.extractionID = nil; self.extraction = nil; self.isLearning = false
                if !(error is CancellationError) {
                    self.notice = "回覆已完成；這次記憶整理未完成，既有資料不變。你也可以到記憶與資料手寫一條。"
                }
            }
        }
    }

    func cancelLearning() {
        generation = UUID()
        extractionID = nil
        extraction?.cancel(); extraction = nil; isLearning = false
    }

    func resetConversationPresentation() {
        cancelLearning()
        notes = []; notice = nil
    }

    private func persist(memory: MemoryState, skills: SkillsState) throws {
        guard available, let vault else { throw LearningFileError.notLoaded }
        try vault.save(LearningSnapshot(memory: memory, skills: skills))
    }

    private static func message(_ error: Error) -> String {
        if let memory = error as? MemoryError {
            switch memory {
            case .sensitiveContent: return "密碼、驗證碼、金鑰與其他敏感資料不能存入記憶。"
            case .invalidContent: return "請輸入 1–200 字的記憶。"
            case .capacityExceeded: return "記憶已達 500 條上限，請先整理。"
            case .duplicate: return "這條記憶已經存在。"
            case .stalePlan: return "資料已有新變更，舊的整理結果未套用。"
            default: return "記憶變更未完成，請檢查內容後重試。"
            }
        }
        if let skill = error as? SkillsError {
            switch skill {
            case .unknownTool: return "技能引用了此版本尚未提供的工具，未匯入或啟用。"
            case .sensitiveContent: return "技能內含可能的敏感資料，未儲存。"
            case .changedSinceRead: return "原技能已被修改，請重新檢查更新內容。"
            case .draftPending: return "同名技能已有待確認草稿，請先處理。"
            case .missingSection: return "技能須包含入口、步驟、容易出錯的地方、怎樣算辦成、什麼時候停下交給使用者五個段落。"
            case .tooLong: return "技能全文超過 4,000 字上限。"
            case .capacityReached: return "技能或版本紀錄已達儲存上限；現有資料保留，這次變更未儲存。"
            default: return "技能格式或狀態不符，未儲存；請檢查名稱、描述與全文。"
            }
        }
        return "無法儲存記憶資料，變更未套用。請解鎖裝置後重試。"
    }

    private static func location() throws -> (url: URL, service: String, reset: Bool) {
        var scope = "personal"
        var reset = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UITestMode") || arguments.contains("-LiveModelUITest") {
            let flag = arguments.contains("-LiveModelUITest") ? "-LiveModelUITestNamespace" : "-UITestNamespace"
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  let id = UUID(uuidString: arguments[index + 1]) else { throw LearningFileError.invalidData }
            scope = "test-" + id.uuidString
            reset = arguments.contains("-UITestResetStorage") || arguments.contains("-LiveModelUITestCleanup")
        }
        #endif
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let url = root.appendingPathComponent("Learning/" + scope, isDirectory: true).appendingPathComponent("learning.vault")
        return (url, "io.woowtech.assistant.learning.v1." + scope, reset)
    }
}
