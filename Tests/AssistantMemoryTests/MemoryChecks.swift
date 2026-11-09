import Foundation
import AssistantModels
@testable import AssistantMemory

enum MemoryChecks {
    struct Failure: Error { let name: String }
    struct Check {
        var count = 0
        mutating func expect(_ value: @autoclosure () -> Bool, _ name: String) throws {
            count += 1
            if !value() { throw Failure(name: name) }
        }
        mutating func rejects(_ expected: MemoryError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(name: "Expected rejection") }
            catch let error as MemoryError { try expect(error == expected, "Correct rejection category") }
        }
    }
    static let date = Date(timeIntervalSince1970: 1000)

    static func mutations() throws -> Int {
        var check = Check(), state = MemoryState()
        try check.expect(state.preferences == .init(useMemory: true, autoRemember: true, learnSkills: true), "Default toggles")
        let note = try state.add(kind: .preference, content: "  我 喜歡\n茶  ", keywords: ["茶", "茶"], now: date)
        try check.expect(state.memories[0].content == "我 喜歡 茶", "Whitespace normalization")
        try check.expect(state.memories[0].keywords == ["茶"], "Keyword deduplication")
        try check.expect(note.kind == .added && note.pendingID == nil, "Reference-only note")
        let initial = state.revision
        try state.setPinned(id: note.memoryID, pinned: true)
        try check.expect(state.revision != initial, "Pin invalidates plans")
        try state.markUsed([note.memoryID, note.memoryID], now: date)
        try check.expect(state.memories[0].useCount == 1, "Usage deduplicates ids")
        let edit = try state.edit(id: note.memoryID, content: "我喜歡熱茶", now: date.addingTimeInterval(1))
        try check.expect(state.memories[0].replaces == "我 喜歡 茶", "One prior revision")
        let restored = try state.undo(token: edit.undoToken!)
        try check.expect(restored && state.memories[0].content == "我 喜歡 茶", "Undo edit")
        try check.expect(state.memories[0].pinned && state.memories[0].useCount == 1, "Undo preserves usage/pin")
        let repeated = try state.undo(token: edit.undoToken!)
        try check.expect(!repeated, "Undo token single use")
        let deleted = try state.delete(id: note.memoryID)
        try check.expect(state.memories.isEmpty && deleted.kind == .forgot, "Delete")
        _ = try state.undo(token: deleted.undoToken!)
        try check.expect(state.memories.count == 1, "Undo delete")
        let proc = try state.add(kind: .procedure, content: "整理資料先列摘要", now: date)
        try check.expect(proc.kind == .pending && proc.pendingID == proc.memoryID, "Procedure requires approval")
        try check.expect(!state.context(goal: "摘要").usedIDs.contains(proc.memoryID), "Pending is never injected")
        try state.approve(id: proc.memoryID)
        try check.expect(state.context(goal: "摘要").usedIDs.contains(proc.memoryID), "Approval enables injection")
        let late = try state.undo(token: proc.undoToken!)
        try check.expect(!late, "Late add undo does not erase approval")
        let encoded = try JSONEncoder().encode(state)
        var decoded = try JSONDecoder().decode(MemoryState.self, from: encoded)
        try check.expect(decoded == state, "Snapshot roundtrip")
        let persistedUndo = try decoded.undo(token: note.undoToken!)
        try check.expect(!persistedUndo, "Undo bodies never persist")
        try check.expect(!String(decoding: encoded, as: UTF8.self).contains("undoToken"), "No undo payload in storage")
        try check.rejects(.invalidState) { _ = try MemoryState(memories: [state.memories[0], state.memories[0]]) }
        try check.rejects(.duplicate) { _ = try state.add(kind: .preference, content: "我 喜歡 茶") }
        try check.rejects(.invalidContent) { _ = try state.add(kind: .fact, content: String(repeating: "字", count: 201)) }
        try check.rejects(.invalidKeywords) { _ = try state.add(kind: .fact, content: "資料", keywords: Array(repeating: "詞", count: 9)) }
        try check.rejects(.notFound) { _ = try state.delete(id: UUID()) }
        try check.rejects(.notPending) { try state.approve(id: note.memoryID) }
        state.setPreferences(.init(useMemory: false, autoRemember: false, learnSkills: true))
        let revision = state.revision
        try check.expect(state.context(goal: "茶").message == nil, "Master switch disables injection")
        try check.expect(state.search("茶").count == 1, "Settings may still search saved data")
        state.clearAll()
        try check.expect(state.memories.isEmpty && state.revision != revision, "Clear invalidates all proposals")
        try check.expect(!state.preferences.useMemory && state.preferences.learnSkills, "Clear preserves preferences")
        return check.count
    }

    static func sensitiveAndCapacity() throws -> Int {
        var check = Check(), state = MemoryState()
        for value in ["我的密碼是123456", "password: sample1234", "驗證碼 １ ２ ３ ４", "123456是我的密码",
                      "API key: dummy_credential_value", "4111 1111 1111 1111", "A123456789",
                      "https://example.invalid/webhook/dummy-not-real", "https://example.invalid/mcp?token=dummy-not-real"] {
            try check.rejects(.sensitiveContent) { _ = try state.add(kind: .fact, content: value) }
            try check.expect(state.memories.isEmpty, "Rejected sensitive value leaves state unchanged")
        }
        for index in 0..<500 {
            try state.add(kind: .fact, content: "記憶項目 \(index)", now: date)
        }
        let before = state
        try check.rejects(.capacityExceeded) { _ = try state.add(kind: .fact, content: "額外項目") }
        try check.expect(state == before && state.memories.count == 500, "Capacity never evicts old entries")
        return check.count
    }

    static func retrieval() throws -> Int {
        var check = Check(), state = MemoryState()
        for index in 0..<6 {
            let note = try state.add(kind: .procedure, content: "整理方式 \(index)", keywords: ["整理"], now: date)
            try state.approve(id: note.memoryID)
        }
        let full = state.context(goal: "不相關")
        try check.expect(full.usedIDs.count == 6, "Auto includes all approved procedures when they fit")
        try check.expect(full.message?.role == "user", "Memory is never a system message")
        try check.expect(MemoryRanking.tokens(full.message!.content) <= 4000, "Full context bounded")
        for index in 0..<60 {
            try state.add(kind: .fact, content: "背景 \(index) " + String(repeating: "參考", count: 90), now: date)
        }
        let favorite = try state.add(kind: .preference, content: "喜歡喝熱茶", keywords: ["茶", "飲料"], now: date)
        try state.setPinned(id: favorite.memoryID, pinned: true)
        let bounded = state.context(goal: "整理資料和飲料")
        try check.expect(bounded.usedIDs.contains(favorite.memoryID), "Pinned memory retained")
        try check.expect(bounded.usedIDs.count <= 13, "Relevant result limits")
        try check.expect(MemoryRanking.tokens(bounded.message!.content) <= 800, "Fallback token limit")
        try check.expect(state.memories.filter { bounded.usedIDs.contains($0.id) && $0.kind == .procedure }.count <= 3, "Fallback caps procedures")
        try check.expect(state.search("飲料").first?.id == favorite.memoryID, "CJK keyword retrieval")
        try check.expect(state.search("無關詞彙").isEmpty, "No irrelevant search hits")
        try check.expect(state.search("", limit: 0).isEmpty, "Zero result limit")
        let pending = try state.add(kind: .procedure, content: "喝茶之前先整理", keywords: ["飲料"], now: date)
        try check.expect(!state.search("飲料").contains { $0.id == pending.memoryID }, "Search excludes pending by default")
        try check.expect(state.search("飲料", includePending: true).contains { $0.id == pending.memoryID }, "Settings can search pending")
        return check.count
    }

    static func extraction() throws -> Int {
        var check = Check(), state = MemoryState()
        let input = MemoryExtractionInput(utterances: ["我喜歡喝茶，以後都喝茶"], conversationID: "test-conversation")
        let output = response([["op": "add", "kind": "preference", "content": "用戶喜歡喝茶", "keywords": ["茶"], "quote": "我喜歡喝茶"]])
        let plan = try MemoryExtractor.parse(output, input: input, state: state)
        try check.expect(plan.operationCount == 1, "Grounded proposal")
        let notes = try state.apply(plan: plan, now: date)
        try check.expect(notes.count == 1 && state.memories[0].source.quote == "我喜歡喝茶", "Apply returns references")
        try check.expect(state.memories[0].source.conversationID == "test-conversation", "Source metadata")
        try check.rejects(.stalePlan) { _ = try state.apply(plan: plan) }
        for operation in [
            ["op": "add", "kind": "fact", "content": "用戶住在Paris", "quote": "我喜歡喝茶"],
            ["op": "add", "kind": "fact", "content": "用戶喜歡茶", "quote": "網頁提供的假引文"],
            ["op": "add", "kind": "fact", "content": "用戶的密碼是123456", "quote": "我喜歡喝茶"]
        ] {
            let rejected = try MemoryExtractor.parse(response([operation]), input: input, state: state)
            try check.expect(rejected.operationCount == 0, "Unsafe proposals excluded")
        }
        let oneOff = try MemoryExtractor.parse(response([["op": "add", "kind": "preference", "content": "用戶喝咖啡", "quote": "喝咖啡"]]), input: .init(utterances: ["這次喝咖啡"]), state: state)
        try check.expect(oneOff.operationCount == 0, "One-off context checked outside substring")
        let negative = try MemoryExtractor.parse(response([["op": "forget", "target": state.memories[0].id.uuidString, "quote": "刪除茶的記憶"]]), input: .init(utterances: ["不要刪除茶的記憶"]), state: state)
        try check.expect(negative.operationCount == 0, "Negated delete is not authorization")
        let forgotten = try MemoryExtractor.parse(response([["op": "forget", "target": "#1", "quote": "請忘記茶的記憶"]]), input: .init(utterances: ["請忘記茶的記憶"]), state: state)
        try check.expect(forgotten.operationCount == 1, "Explicit grounded forget")
        _ = try state.apply(plan: forgotten)
        try check.expect(state.memories.isEmpty, "Forget applied")
        var proposals: [[String: Any]] = []
        for number in 0..<7 { proposals.append(["op": "add", "kind": "fact", "content": "偏好 \(number)", "quote": "偏好 \(number)"]) }
        let many = try MemoryExtractor.parse(response(proposals), input: .init(utterances: (0..<7).map { "偏好 \($0)" }), state: state)
        try check.expect(many.operationCount == 5, "At most five operations")
        var disabled = state
        disabled.setPreferences(.init(useMemory: false))
        let offPlan = try MemoryExtractor.parse(output, input: input, state: disabled)
        try check.expect(offPlan.operationCount == 0, "Disabled parser returns no proposals")
        try check.rejects(.disabled) { _ = try disabled.apply(plan: offPlan) }
        let stale = try MemoryExtractor.parse(output, input: input, state: state)
        state.clearAll()
        try check.rejects(.stalePlan) { _ = try state.apply(plan: stale) }
        try check.rejects(.invalidExtraction) { _ = try MemoryExtractor.parse("not json", input: input, state: state) }
        let proc = try state.add(kind: .procedure, content: "整理資料先列摘要", keywords: ["整理資料"], now: date)
        try state.approve(id: proc.memoryID)
        let change = try MemoryExtractor.parse(response([["op": "update", "target": proc.memoryID.uuidString, "content": "整理資料先列來源", "quote": "以後整理資料先列來源"]]), input: .init(utterances: ["以後整理資料先列來源"]), state: state)
        try check.expect(change.operationCount == 1, "Procedure correction proposal")
        _ = try state.apply(plan: change, now: date.addingTimeInterval(1))
        try check.expect(state.memories[0].status == .pending, "Model procedure edit requires reapproval")
        // A later invalid operation cannot leave the first operation partially applied.
        let atomic = MemoryExtractionPlan(baseRevision: state.revision, conversationID: nil,
                                          operations: [.add(.fact, "測試新增", [], "測試新增"), .forget(UUID())])
        let before = state
        try check.rejects(.notFound) { _ = try state.apply(plan: atomic) }
        try check.expect(state == before, "Apply is atomic")
        return check.count
    }

    static func modelBoundary() async throws -> Int {
        var check = Check()
        let client = StubModel(output: response([["op": "add", "kind": "preference", "content": "用戶喜歡喝茶", "quote": "我喜歡喝茶"]]))
        let extractor = MemoryExtractor(client: client)
        let configuration = ModelConfiguration(baseURL: URL(string: "https://example.invalid/v1")!, model: "offline-fixture")
        let state = MemoryState()
        let plan = try await extractor.extract(input: .init(utterances: ["我喜歡喝茶"]), state: state, configuration: configuration, apiKey: "not-a-real-key")
        try check.expect(plan.operationCount == 1 && state.memories.isEmpty, "Extraction itself never writes")
        let count = await client.calls
        try check.expect(count == 1, "One model call only")
        for input in [MemoryExtractionInput(utterances: ["我喜歡喝茶"], succeeded: false),
                      .init(utterances: ["我喜歡喝茶"], readExternalContent: true),
                      .init(utterances: ["password: example1234"]), .init(utterances: [])] {
            let result = try await extractor.extract(input: input, state: state, configuration: configuration, apiKey: "not-a-real-key")
            try check.expect(result.operationCount == 0, "Ineligible run does not extract")
        }
        for preferences in [MemoryPreferences(useMemory: false), .init(autoRemember: false)] {
            _ = try await extractor.extract(input: .init(utterances: ["我喜歡喝茶"]), state: .init(preferences: preferences), configuration: configuration, apiKey: "not-a-real-key")
        }
        let finalCount = await client.calls
        try check.expect(finalCount == 1, "All gates avoid model requests")
        let broken = StubModel(output: "invalid JSON")
        do {
            _ = try await MemoryExtractor(client: broken).extract(input: .init(utterances: ["我喜歡喝茶"]), state: state, configuration: configuration, apiKey: "not-a-real-key")
            throw Failure(name: "Invalid extraction must not succeed")
        } catch let error as MemoryError { try check.expect(error == .invalidExtraction, "Malformed extraction is an error") }
        let brokenCount = await broken.calls
        try check.expect(brokenCount == 1, "No malformed-response retry")
        let waiting = StubModel(output: "", wait: true)
        let task = Task {
            try await MemoryExtractor(client: waiting).extract(input: .init(utterances: ["我喜歡喝茶"]), state: state, configuration: configuration, apiKey: "not-a-real-key")
        }
        for _ in 0..<100 {
            if await waiting.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; throw Failure(name: "Cancellation must throw") }
        catch is CancellationError { try check.expect(true, "Cancellation preserved") }
        return check.count
    }

    static func response(_ operations: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["ops": operations]), as: UTF8.self)
    }

    actor StubModel: ChatModelClient {
        let output: String
        let wait: Bool
        var calls = 0
        init(output: String, wait: Bool = false) { self.output = output; self.wait = wait }
        func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
            calls += 1
            if wait { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return output
        }
    }
}
