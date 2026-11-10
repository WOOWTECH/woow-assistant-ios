import AssistantMemory
import AssistantBrowser
import AssistantModels
import AssistantPersistence
import AssistantSkills
import Combine
import Foundation

private struct LearningSnapshot: Codable {
    let version: Int
    let memory: MemoryState
    let skills: SkillsState
    let websites: WebsiteKnowledgeState?
    let routes: WebRouteState?
    let profile: UserProfileState?
    init(memory: MemoryState = .init(), skills: SkillsState = .init(),
         websites: WebsiteKnowledgeState = .init(), routes: WebRouteState = .init(),
         profile: UserProfileState = .init()) {
        version = 2; self.memory = memory; self.skills = skills
        self.websites = websites; self.routes = routes; self.profile = profile
    }
}

@MainActor
final class LearningStore: ObservableObject, SkillAuthoringStoring {
    @Published private(set) var memory = MemoryState()
    @Published private(set) var skills = SkillsState()
    @Published private(set) var websites = WebsiteKnowledgeState()
    @Published private(set) var routes = WebRouteState()
    @Published private(set) var profile = UserProfileState()
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var isLearning = false
    @Published private(set) var available = false
    private var vault: EncryptedLearningFile?
    private var extraction: Task<Void, Never>?
    private var extractionID: UUID?
    private(set) var generation = UUID()
    var onUserChange: (() -> Void)?
    var referenceSnapshots: [WeakLearningRunSnapshot] = []
    var referenceEditInProgress = false

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

    /// Allows isolated tests to exercise the real encrypted store without the
    /// personal Keychain service or production Application Support location.
    init(vault: EncryptedLearningFile) {
        self.vault = vault
        reload()
    }

    func reload() {
        revokeRunReferences()
        onUserChange?()
        cancelLearning()
        do {
            guard let vault else { throw LearningFileError.unavailable }
            let snapshot = try vault.load(LearningSnapshot.self) ?? LearningSnapshot()
            guard snapshot.version == 1 || snapshot.version == 2 else { throw LearningFileError.invalidData }
            memory = snapshot.memory; skills = snapshot.skills
            websites = snapshot.websites ?? .init(); routes = snapshot.routes ?? .init()
            profile = snapshot.profile ?? .init()
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
        notifyReferenceEdit()
        cancelLearning()
        do {
            var next = memory
            try change(&next)
            try persist(memory: next, skills: skills)
            checkMemoryReferenceRemoval(next)
            memory = next
            notes = notes.filter { note in
                if note.kind == .forgot, let token = note.undoToken {
                    return memory.canUndo(token: token)
                }
                return memory.memories.contains { $0.id == note.memoryID }
            }
            error = nil; notice = nil
            return true
        } catch { self.error = Self.message(error); return false }
    }

    /// Add/delete profile data without inferring replacement ancestry. Manual
    /// replacements must use replaceProfileReference so a later deletion can
    /// revoke the old frozen version without changing its text during this run.
    @discardableResult
    func mutateProfile(revokingRemovedEntries: Bool = false, _ change: (inout UserProfileState) throws -> Void) -> Bool {
        notice = nil
        do {
            guard available else { throw LearningFileError.notLoaded }
            var next = profile
            try change(&next)
            try persist(memory: memory, skills: skills, profile: next)
            if revokingRemovedEntries {
                revokeDeletedProfileReferences(in: next)
            }
            profile = next; error = nil
            notice = "個人檔案已儲存，下一次對話任務開始時生效。"
            return true
        } catch { self.error = Self.message(error); return false }
    }

    /// Reviewed tool transaction. Recheck the master switch and both revisions
    /// synchronously, persist a disposable value, then publish its receipt.
    func commitProfileTool(_ review: UserProfileToolReview,
                           expectedGeneration: UUID) throws -> UserProfileToolReceipt {
        guard available else { throw LearningFileError.notLoaded }
        guard memory.preferences.useMemory else { throw MemoryError.disabled }
        guard generation == expectedGeneration else { throw UserProfileToolError.staleRevision }
        var next = profile
        let receipt = try review.apply(to: &next, now: Date())
        let replacedID = review.op == .replace ? try replacedProfileID(in: next) : nil
        if replacedID != nil, receipt.id == nil { throw UserProfileError.invalidState }
        do { try persist(memory: memory, skills: skills, profile: next) }
        catch { self.error = Self.message(error); throw error }
        if let previous = replacedID, let replacement = receipt.id {
            recordProfileReplacement(from: previous, to: replacement)
        }
        if review.op == .delete {
            revokeDeletedProfileReferences(in: next)
        }
        profile = next
        error = nil
        notice = "個人檔案已儲存，下一次對話任務開始時生效。"
        return receipt
    }

    /// Explicit manual replacement preserves frozen text while tracking which
    /// current row's later deletion must revoke it. Publish lineage only after
    /// the encrypted write succeeds, before publishing the changed profile.
    @discardableResult
    func replaceProfileReference(segment: String, replacement: String, expectedRevision: UUID? = nil) -> Bool {
        notice = nil
        do {
            guard available else { throw LearningFileError.notLoaded }
            if let expectedRevision, profile.revision != expectedRevision { throw MemoryError.stalePlan }
            var next = profile
            let entry = try next.replace(segment: segment, replacement: replacement)
            let previous = try replacedProfileID(in: next)
            try persist(memory: memory, skills: skills, profile: next)
            recordProfileReplacement(from: previous, to: entry.id)
            profile = next; error = nil
            notice = "個人檔案已儲存，下一次對話任務開始時生效。"
            return true
        } catch { self.error = Self.message(error); return false }
    }

    /// Called only after one explicit state.replace or reviewed replace, never
    /// to infer lineage from an arbitrary add/delete mutation closure.
    private func replacedProfileID(in next: UserProfileState) throws -> UUID {
        let removed = Set(profile.snapshot().entries.map(\.id))
            .subtracting(next.snapshot().entries.map(\.id))
        guard removed.count == 1, let previous = removed.first else { throw UserProfileError.invalidState }
        return previous
    }

    func commitMemoryTool(_ review: MemoryToolReview, expectedGeneration: UUID,
                          conversationID: String) throws -> MemoryToolReceipt {
        guard available else { throw LearningFileError.notLoaded }
        guard generation == expectedGeneration else { throw MemoryToolError.staleRevision }
        var next = memory
        let receipt = try review.apply(to: &next, conversationID: conversationID, now: Date())
        do { try persist(memory: next, skills: skills) }
        catch { self.error = Self.message(error); throw error }
        checkMemoryReferenceRemoval(next)
        memory = next
        notes = [receipt.note]
        error = nil; notice = nil
        return receipt
    }

    func canReviewMemory(_ note: MemoryNote) -> Bool {
        available && memory.memories.contains { $0.id == note.pendingID && $0.status == .pending }
    }

    func approvePendingMemory(_ note: MemoryNote) {
        guard canReviewMemory(note) else { return }
        if mutateMemory({ try $0.approve(id: note.memoryID) }) {
            notes.removeAll { $0.memoryID == note.memoryID }
            notice = "已批准這條操作偏好，後續任務可以參考。"
        }
    }

    func rejectPendingMemory(_ note: MemoryNote) {
        guard canReviewMemory(note) else { return }
        if mutateMemory({ state in
            if let token = note.undoToken, try state.undo(token: token) { return }
            _ = try state.delete(id: note.memoryID)
        }) {
            notes.removeAll { $0.memoryID == note.memoryID }
            notice = "已拒絕這條操作偏好；有可用撤銷紀錄時恢復修改前內容。"
        }
    }

    @discardableResult
    func mutateSkills(_ change: (inout SkillsState) throws -> Void) -> Bool {
        notifyReferenceEdit()
        cancelLearning()
        do {
            var next = skills
            try change(&next)
            try persist(memory: memory, skills: next)
            checkSkillReferenceRemoval(next)
            skills = next; error = nil; notice = nil
            return true
        } catch { self.error = Self.message(error); return false }
    }

    func skillAuthoringSnapshot() -> SkillAuthoringSnapshot {
        SkillAuthoringSnapshot(state: skills, generation: generation,
            availableToolNames: BrowserSession.toolNames, available: available)
    }

    /// Synchronous MainActor transaction. Check the reviewed generation before
    /// cancellation advances it; never publish a draft or success before disk.
    func commitSkillAuthoring(expectedGeneration: UUID,
                              _ change: (inout SkillsState) throws -> Void) throws {
        guard available else { throw SkillAuthoringError.unavailable }
        guard generation == expectedGeneration else { throw SkillAuthoringError.storageChanged }
        notifyReferenceEdit()
        // A host callback may invalidate the reviewed snapshot synchronously.
        guard generation == expectedGeneration else { throw SkillAuthoringError.storageChanged }
        cancelLearning()
        do {
            var next = skills
            try change(&next)
            try persist(memory: memory, skills: next)
            checkSkillReferenceRemoval(next)
            skills = next; error = nil; notice = nil
        } catch {
            self.error = Self.message(error)
            throw error
        }
    }

    /// Call only after the view has obtained BOTH clear-all confirmations.
    @discardableResult
    func clearAll() -> Bool {
        revokeRunReferences()
        onUserChange?()
        cancelLearning()
        do {
            guard let vault else { throw LearningFileError.unavailable }
            let nextMemory = MemoryState(preferences: memory.preferences)
            let nextSkills = SkillsState()
            let nextProfile = UserProfileState()
            let retiredKeysRemoved = try vault.save(LearningSnapshot(memory: nextMemory, skills: nextSkills, profile: nextProfile), rotateKey: true)
            memory = nextMemory; skills = nextSkills; notes = []; available = true; error = nil
            websites = .init(); routes = .init(); profile = nextProfile
            notice = retiredKeysRemoved
                ? "已清除個人檔案、記憶、技能、網站知識與路線，並更新加密金鑰；模型和 MCP 設定保留。"
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
        // Capture at run start, before the current user request. Profile writes
        // during a run cannot alter the already captured message array.
        let profileMessage = memory.preferences.useMemory ? profile.snapshot().message : nil
        var messages = [profileMessage, context.message].compactMap { $0 }
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
                            configuration: ModelConfiguration, apiKey: String,
                            preservingToolNotes: [MemoryNote] = []) {
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
                    self.checkMemoryReferenceRemoval(next)
                    self.memory = next
                    // A later extraction cannot discard the reviewed tool's
                    // undo card; newer changes to the same ID supersede it.
                    self.notes = preservingToolNotes.filter { previous in
                        !notes.contains { $0.memoryID == previous.memoryID }
                    } + notes
                    self.error = nil
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
        onUserChange?()
        cancelLearning()
        notes = []; notice = nil
    }

    @discardableResult
    func mutateWeb(cancelResearch: Bool = true, _ change: (inout WebsiteKnowledgeState, inout WebRouteState) throws -> Void) -> Bool {
        if cancelResearch { notifyReferenceEdit() }
        cancelLearning()
        do {
            guard available, let vault else { throw LearningFileError.notLoaded }
            var nextWebsites = websites, nextRoutes = routes
            try change(&nextWebsites, &nextRoutes)
            try vault.save(LearningSnapshot(memory: memory, skills: skills, websites: nextWebsites, routes: nextRoutes, profile: profile))
            revokeRunReferences(kind: .website, keeping: Set(nextWebsites.lessons.filter { $0.status == .approved }.map { $0.id.uuidString }))
            websites = nextWebsites; routes = nextRoutes; error = nil
            return true
        } catch { self.error = "網站資料未儲存；請檢查內容、來源與版本，既有資料保留。"; return false }
    }

    func websiteContext(for url: URL) -> String {
        guard available, let lessons = try? websites.context(for: url),
              let data = try? JSONEncoder().encode(lessons.map(\.text)) else { return "" }
        return "Website reference data (user reviewed, exact origin only):\n" + String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    func applyResearch(_ assessment: SkillLearningAssessment, goal: String, actions: [WebResearchAction],
                       expectedGeneration: UUID) -> Bool {
        guard available, generation == expectedGeneration, let vault else { return false }
        do {
            var nextSkills = skills, nextWebsites = websites, nextRoutes = routes
            _ = try nextSkills.apply(assessment, availableToolNames: BrowserSession.toolNames)
            if memory.preferences.learnSkills, assessment.judgment.outcome == .done {
                let task = try WebTaskEvidence(outcome: .succeeded, confirmed: true, summary: "已由獨立成果判定核對網站研究回答。")
                if let citation = assessment.judgment.citations.first,
                   let index = Int(citation.actionID.replacingOccurrences(of: "action-", with: "")),
                   actions.indices.contains(index), actions[index].tool != "browser_find",
                   actions[index].observation.text.contains(citation.quote) {
                    let page = actions[index].observation
                    let snapshot = PageSnapshot(url: page.url, title: page.title, visibleText: page.text, capturedAt: page.capturedAt)
                    if let evidence = try? WebsiteLessonEvidence(snapshot: snapshot, quote: citation.quote),
                       !nextWebsites.lessons.contains(where: { $0.evidence.sourceURL == evidence.sourceURL && $0.text == citation.quote }) {
                        _ = try nextWebsites.propose(text: citation.quote, evidence: evidence, task: task)
                    }
                }
                // A one-page answer is not a reusable multi-step route.
                if actions.filter({ $0.tool == "browser_open_link" }).count >= 2 {
                    let steps = try actions.filter { $0.tool != "browser_find" }.map { action -> WebRouteStep in
                        let page = action.observation
                        return try WebRouteStep(kind: action.tool == "browser_open_link" ? .navigate : .observe,
                            snapshot: PageSnapshot(url: page.url, title: page.title, visibleText: page.text, capturedAt: page.capturedAt),
                            evidenceQuote: String(page.text.prefix(160)))
                    }
                    _ = try nextRoutes.record(intent: goal, steps: steps, task: task)
                }
            }
            try vault.save(LearningSnapshot(memory: memory, skills: nextSkills, websites: nextWebsites, routes: nextRoutes, profile: profile))
            checkSkillReferenceRemoval(nextSkills)
            skills = nextSkills; websites = nextWebsites; routes = nextRoutes; error = nil
            return true
        } catch { self.error = "學習資料未儲存；原有技能、網站知識與路線保留。"; return false }
    }

    func recordResearchFailure(usedSkills: [SkillUsedReference], kind: SkillFailureKind, expectedGeneration: UUID) {
        guard available, generation == expectedGeneration, !usedSkills.isEmpty else { return }
        do {
            var next = skills
            let evidence = SkillRunEvidence(end: .failed, failureKind: kind, wasRead: true)
            for reference in usedSkills { _ = try next.recordOutcome(reference: reference, evidence: evidence) }
            try persist(memory: memory, skills: next)
            checkSkillReferenceRemoval(next)
            skills = next
        } catch { self.error = "任務已停止；技能結果紀錄未能儲存，既有資料保留。" }
    }

    private func persist(memory: MemoryState, skills: SkillsState, profile: UserProfileState? = nil) throws {
        guard available, let vault else { throw LearningFileError.notLoaded }
        try vault.save(LearningSnapshot(memory: memory, skills: skills, websites: websites, routes: routes, profile: profile ?? self.profile))
    }

    @discardableResult
    func importCatalogSkill(id: String, catalog: BundledSkillCatalog) -> Bool {
        mutateSkills { _ = try catalog.stageAdaptation(id: id, into: &$0) }
    }

    static func message(_ error: Error) -> String {
        if let profile = error as? UserProfileError {
            switch profile {
            case .invalidSentence: return "請輸入單句、1–160 字元的個人檔案；不可包含換行、密碼、驗證碼或金鑰等敏感資料。"
            case .duplicate: return "這條個人檔案已經存在。"
            case .profileFull: return "個人檔案已達 20 條上限，請先整理。"
            case .matchNotUnique: return "指定片段必須只出現在一條現用檔案中，而且只出現一次；請重新選擇。"
            case .invalidState: return "個人檔案狀態無效；原資料保留，變更未套用。"
            }
        }
        if let authoring = error as? SkillAuthoringError { return authoring.errorDescription ?? "技能未儲存。" }
        if let catalog = error as? SkillCatalogError { return catalog.errorDescription ?? "內建技能未匯入。" }
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
            case .builtinName: return "這個名稱保留給內建技能，請使用不同的個人技能名稱。"
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
