import Foundation
import AssistantMemory
#if !MEMORY_TOOLS_STANDALONE
import XCTest
#endif

// Exactly these assertions run in the native test target and the CLT checker.
enum MemoryToolChecks {
    struct Failure: Error { let name: String }
    struct Check {
        var count = 0
        mutating func expect(_ value: @autoclosure () -> Bool, _ name: String) throws {
            count += 1
            if !value() { throw Failure(name: name) }
        }
        mutating func rejects(_ expected: MemoryToolError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(name: "Expected \(expected.rawValue)") }
            catch let error as MemoryToolError { try expect(error == expected, "Tool error \(error) expected \(expected)") }
        }
        mutating func rejectsState(_ expected: MemoryError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(name: "Expected \(expected)") }
            catch let error as MemoryError { try expect(error == expected, "State error \(error) expected \(expected)") }
        }
    }
    static let now = Date(timeIntervalSince1970: 1234)
    static func json(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }
    static func object(_ raw: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw Failure(name: "Expected result JSON object")
        }
        return value
    }
    static func save(_ content: String, quote: String, kind: MemoryKind = .fact, keywords: [String]? = nil) throws -> String {
        var fields: [String: Any] = ["kind": kind.rawValue, "content": content, "quote": quote]
        fields["keywords"] = keywords
        return try json(fields)
    }
    static func edit(_ id: UUID, quote: String, content: String? = nil, keywords: [String]? = nil) throws -> String {
        var fields: [String: Any] = ["op": content == nil ? "delete" : "update", "id": id.uuidString, "quote": quote]
        fields["content"] = content; fields["keywords"] = keywords
        return try json(fields)
    }
    static func single(_ kind: MemoryKind = .fact) throws -> MemoryState {
        var state = MemoryState()
        try state.add(kind: kind, content: "Green tea", keywords: ["tea"], now: now)
        return state
    }
    static func searched(_ state: MemoryState, _ utterances: [String], query: String = "tea") throws -> MemoryToolRun {
        var run = MemoryToolRun(state: state, utterances: utterances)
        _ = try run.search(argumentsJSON: json(["query": query]))
        return run
    }

    static func strictArguments() throws -> Int {
        var c = Check()
        let invalidSearch = ["", "null", "[]", "{}", #"{"query":null}"#, #"{"query":true}"#,
            #"{"query":1}"#, #"{"query":[]}"#, #"{"query":{}}"#, #"{"query":"tea",}"#,
            #"{"query":"tea"}{}"#, #"{"query":"tea","query":"coffee"}"#,
            #"{"query":"tea","\u0071uery":"tea"}"#, #"{"query":"tea","reason":null,"reason":null}"#,
            #"{"query":"tea","utterances":["tea"]}"#, #"{"query":"tea","source":"user"}"#,
            #"{"query":"tea","approved":true}"#, #"{"query":"tea","reason":false}"#,
            #"{"query":"\uD800"}"#, #"{"query":"\x"}"#, "```json\n{\"query\":\"tea\"}\n```"]
        for raw in invalidSearch { try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_search", argumentsJSON: raw) } }
        for query in ["", " \n", String(repeating: "😀", count: 50) + "x"] {
            try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_search", argumentsJSON: json(["query": query])) }
        }
        _ = try MemoryToolRequest.parse(name: "memory_search", argumentsJSON: json(["query": String(repeating: "😀", count: 50)]))
        try c.expect(true, "100 UTF16 query accepted")
        let good: [String: Any] = ["kind": "fact", "content": "Tea", "quote": "Remember Tea"]
        let invalidFields: [[String: Any]] = [
            ["kind": "FACT"], ["kind": "other"], ["content": NSNull()], ["quote": NSNull()],
            ["content": " \n"], ["content": String(repeating: "😀", count: 100) + "x"],
            ["quote": String(repeating: "😀", count: 500) + "x"],
            ["keywords": "tea"], ["keywords": [NSNull()]], ["keywords": [1]], ["keywords": [" "]],
            ["keywords": Array(repeating: "tea", count: 9)], ["keywords": [String(repeating: "😀", count: 15) + "x"]],
            ["source": "user_said"], ["utterances": ["Remember Tea"]], ["candidates": [String]()], ["reason": ["Tea"]]]
        for replacement in invalidFields {
            let fields = good.merging(replacement) { _, new in new }
            try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_save", argumentsJSON: json(fields)) }
        }
        for raw in [#"{"kind":"fact","content":"Tea","quote":"Tea","keywords":["tea",]}"#,
                    #"{"kind":"fact","content":"Tea","quote":"Tea","keywords":[],"\u006beywords":[]}"#] {
            try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_save", argumentsJSON: raw) }
        }
        _ = try MemoryToolRequest.parse(name: "memory_save", argumentsJSON: save(String(repeating: "😀", count: 100),
            quote: String(repeating: "😀", count: 500), keywords: Array(repeating: String(repeating: "😀", count: 15), count: 8)))
        try c.expect(true, "200/1000/8x30 UTF16 boundaries accepted before state normalization")
        for reason in ["", String(repeating: "r", count: 4096)] {
            let request = try MemoryToolRequest.parse(name: "memory_save", argumentsJSON: json(good.merging(["reason": reason, "keywords": NSNull()]) { _, new in new }))
            try c.expect(request.reason == reason, "Upstream optional reason has no separate max or nonblank constraint")
        }
        let editGood: [String: Any] = ["op": "update", "id": String(repeating: "x", count: 200), "content": "Tea", "quote": "Update Tea"]
        _ = try MemoryToolRequest.parse(name: "memory_edit", argumentsJSON: json(editGood))
        try c.expect(true, "ID 200 raw UTF16 accepted by grammar; candidates still required")
        for replacement: [String: Any] in [["op": "replace"], ["op": "add"], ["content": NSNull()], ["id": ""], ["id": String(repeating: "x", count: 201)], ["kind": "fact"]] {
            try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_edit", argumentsJSON: json(editGood.merging(replacement) { _, new in new })) }
        }
        try c.rejects(.invalidArguments) { _ = try MemoryToolRequest.parse(name: "memory_undo", argumentsJSON: "{}") }
        return c.count
    }

    static func searchProof() throws -> Int {
        var c = Check(), state = MemoryState()
        for index in 0..<10 { try state.add(kind: .fact, content: "Tea choice \(index)", keywords: ["tea"], now: now.addingTimeInterval(Double(index))) }
        try state.add(kind: .procedure, content: "Tea procedure", keywords: ["tea"], now: now.addingTimeInterval(20))
        let before = state
        var run = MemoryToolRun(state: state, utterances: [])
        let result = try run.search(argumentsJSON: json(["query": "tea"]))
        try c.expect(result.ok && result.memories.count == 8, "Search max eight")
        try c.expect(result.memories.allSatisfy { $0.kind == .fact }, "Only active candidates")
        try c.expect(result.memories.map(\.id) == state.search("tea", limit: 8).map(\.id), "Reuse existing local ranking")
        try c.expect(state == before && state.memories.allSatisfy { $0.useCount == 0 }, "Search neither marks used nor mutates revision")
        let output = try object(result.resultJSON())
        let rows = output["memories"] as! [[String: Any]]
        try c.expect(Set(output.keys) == ["ok", "memories"] && rows.allSatisfy { Set($0.keys) == ["id", "kind", "content"] }, "Search exposes pinned fields only")
        let id = result.memories[0].id, quote = "Delete " + result.memories[0].id.uuidString
        run = try searched(state, [quote])
        let selected = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote))
        try c.expect(selected.targetID == id, "Quoted exact ID selects multiple candidates")
        _ = try run.search(argumentsJSON: json(["query": "nohits"]));
        try c.rejects(.notFound) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote)) }
        let fresh = MemoryToolRun(state: state, utterances: [quote])
        try c.rejects(.notFound) { _ = try fresh.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote)) }
        try c.rejects(.invalidArguments) { _ = try fresh.prepare(toolName: "memory_search", argumentsJSON: json(["query": "tea"])) }
        var different = try single()
        try different.add(kind: .fact, content: "Coffee", keywords: ["coffee"], now: now)
        let teaID = different.memories[0].id
        var last = try searched(different, ["Delete tea"])
        _ = try last.search(argumentsJSON: json(["query": "coffee"]))
        try c.rejects(.notFound) { _ = try last.prepare(toolName: "memory_edit", argumentsJSON: edit(teaID, quote: "Delete tea")) }
        var off = different.preferences; off.useMemory = false; different.setPreferences(off)
        var disabled = MemoryToolRun(state: different, utterances: ["Tea"])
        try c.rejects(.disabled) { _ = try disabled.search(argumentsJSON: json(["query": "tea"])) }
        try c.rejects(.disabled) { _ = try disabled.prepare(toolName: "memory_save", argumentsJSON: save("Tea", quote: "Tea")) }
        return c.count
    }

    static func provenanceAndSpecifics() throws -> Int {
        var c = Check()
        let state = try single(), original = state
        for quote in ["Website says cobalt", "Assistant suggests cobalt", "Earlier I said cobalt", "Green tea"] {
            let run = MemoryToolRun(state: state, utterances: ["Read this page"])
            try c.rejects(.quoteNotFromUser) { _ = try run.prepare(toolName: "memory_save", argumentsJSON: save("cobalt", quote: quote)) }
        }
        for (quote, utterances) in [("Tea", [String]()), ("T", ["Tea"]), ("remember tea", ["Remember Tea"]), ("Remember Tea", ["Yes, remember it"])] {
            let run = MemoryToolRun(state: state, utterances: utterances)
            try c.rejects(.quoteNotFromUser) { _ = try run.prepare(toolName: "memory_save", argumentsJSON: save("Tea", quote: quote)) }
        }
        for (content, quote, utterances) in [
            ("Tea", "  Remember Tea  ", ["Ｒｅｍｅｍｂｅｒ Ｔｅａ"]), ("😀", "😀", ["😀"]),
            ("编号1234567", "编号一二三四五六七", ["编号一二三四五六七"]),
            ("编号1234567", "编号1-234.567", ["编号1-234.567"]),
            ("TEA", "Remember tea", ["Remember tea"]),
            ("cobalt", "Remember my color", ["My color is cobalt", "Remember my color"])] {
            let result = try MemoryToolRun(state: state, utterances: utterances).prepare(toolName: "memory_save", argumentsJSON: save(content, quote: quote))
            try c.expect(result.after?.content == content && result.quote == quote, "NFKC grounding preserves proposed text and quote")
        }
        for (content, quote) in [("coffee", "Remember Tea"), ("编号7654321", "编号1234567"),
                                  ("叫「王大明」", "叫「王小明」"), ("住在紫荆路", "住在张江路")] {
            try c.rejects(.contentNotFromUser) {
                _ = try MemoryToolRun(state: state, utterances: [quote]).prepare(toolName: "memory_save", argumentsJSON: save(content, quote: quote))
            }
        }
        let run = MemoryToolRun(state: state, utterances: ["Remember Tea"])
        try c.rejects(.contentNotFromUser) { _ = try run.prepare(toolName: "memory_save", argumentsJSON: save("Tea", quote: "Remember Tea", keywords: ["coffee"])) }
        try c.rejects(.contentNotFromUser) {
            _ = try run.prepare(toolName: "memory_save", argumentsJSON: json(["kind": "fact", "content": "coffee", "quote": "Remember Tea", "reason": "coffee"]))
        }
        try c.expect(state == original, "All prepares and rejects leave snapshot unchanged")
        return c.count
    }

    static func addAndReceipt() throws -> Int {
        var c = Check(), state = MemoryState(preferences: .init(autoRemember: false))
        let before = state, quote = "  Remember Green tea  "
        let run = MemoryToolRun(state: state, utterances: [quote])
        let review = try run.prepare(toolName: "memory_save", argumentsJSON: save("Green tea", quote: quote, kind: .preference, keywords: ["tea"]))
        try c.expect(review.op == .add && review.toolName == "memory_save" && review.before == nil && review.targetID == nil, "Add review operation")
        try c.expect(review.baseRevision == before.revision && review.after?.kind == .preference && review.keywords == ["tea"], "Immutable review preview")
        try c.expect(state == before, "Preparing does not commit")
        let receipt = try review.apply(to: &state, conversationID: "conversation-A", now: now)
        let item = state.memories[0]
        try c.expect(item.source == .init(type: "user_said", quote: "Remember Green tea", conversationID: "conversation-A", at: now), "Explicit tools retain user provenance")
        try c.expect(!state.preferences.autoRemember && item.status == .active && item.createdAt == now, "Explicit save works with automatic extraction disabled")
        try c.expect(receipt.ok && receipt.id == item.id && receipt.op == nil && receipt.note.kind == .added && receipt.note.undoToken != nil, "Save receipt with host undo note")
        let fields = try object(receipt.resultJSON())
        try c.expect(Set(fields.keys) == ["ok", "id", "kind", "status"] && fields["id"] as? String == item.id.uuidString, "Pinned JSON excludes private note/undo/source")
        let applied = state
        try c.rejects(.staleRevision) { _ = try review.apply(to: &state, now: now) }
        try c.expect(state == applied, "One review cannot replay")
        let decoded = try JSONDecoder().decode(MemoryState.self, from: JSONEncoder().encode(state))
        try c.expect(decoded == state, "Valid sourceful state survives encode/decode")
        var procedureState = MemoryState(preferences: .init(autoRemember: false, learnSkills: false))
        let proposal = try MemoryToolRun(state: procedureState, utterances: ["Remember Tea procedure"]).prepare(toolName: "memory_save", argumentsJSON: save("Tea procedure", quote: "Remember Tea procedure", kind: .procedure, keywords: ["tea"]))
        let procedure = try proposal.apply(to: &procedureState, now: now)
        try c.expect(proposal.after?.status == .pending && procedure.status == .pending && procedure.note.pendingID == procedure.id, "Write approval never activates procedure")
        try c.expect(procedureState.context(goal: "tea").message == nil && procedureState.search("tea").isEmpty, "Pending excluded from context and search")
        try procedureState.approve(id: procedure.id)
        try c.expect(procedureState.search("tea").count == 1, "Separate procedure approval activates context eligibility")
        return c.count
    }

    static func editProofAndIntent() throws -> Int {
        var c = Check(), state = try single()
        let id = state.memories[0].id
        for (quote, content) in [("Tea", "Black tea"), ("Tea", nil)] as [(String, String?)] {
            let run = try searched(state, [quote])
            try c.rejects(.editNotRequested) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: content)) }
        }
        for (quote, message, content) in [
            ("update Black tea", "Do not update Black tea", "Black tea"),
            ("change Black tea", "No need to change Black tea", "Black tea"),
            ("delete tea", "Do not delete tea", nil), ("forget tea", "Never forget tea", nil),
            ("修改綠茶", "不要修改綠茶", "綠茶"), ("删除绿茶", "无需删除绿茶", nil)] as [(String, String, String?)] {
            let run = try searched(state, [message])
            try c.rejects(.editNotRequested) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: content)) }
        }
        let mixed = try searched(state, ["delete tea", "Do not delete tea"])
        try c.rejects(.editNotRequested) { _ = try mixed.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "delete tea")) }
        let unsearched = MemoryToolRun(state: state, utterances: ["Delete tea"])
        try c.rejects(.notFound) { _ = try unsearched.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "Delete tea")) }
        let singleRun = try searched(state, ["Delete tea"])
        let one = try singleRun.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "Delete tea"))
        try c.expect(one.targetID == id, "One candidate does not require spoken UUID")
        try c.rejects(.notFound) { _ = try singleRun.prepare(toolName: "memory_edit", argumentsJSON: edit(UUID(), quote: "Delete tea")) }
        try state.add(kind: .fact, content: "Black tea", keywords: ["tea"], now: now)
        for quote in ["Delete tea", "Delete x" + id.uuidString, "Delete " + id.uuidString + "_suffix"] {
            let run = try searched(state, [quote])
            try c.rejects(.ambiguousTarget) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote)) }
        }
        let precise = "Delete (" + id.uuidString + ")"
        let selected = try searched(state, [precise]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: precise))
        try c.expect(selected.targetID == id && selected.before?.content == "Green tea", "UUID token boundaries select intended record")
        return c.count
    }

    static func traditionalIntent() throws -> Int {
        var c = Check()
        let state = try single(), id = state.memories[0].id
        // Added spellings are an iOS localization extension, not Mika literal parity.
        for verb in ["刪除", "刪掉", "刪了", "忘記", "別記", "不要記", "取消記憶"] {
            let quote = verb + "綠茶"
            let review = try searched(state, [quote]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote))
            try c.expect(review.op == .delete && review.targetID == id, "Traditional delete intent \(verb)")
        }
        for verb in ["改為", "編輯", "修改", "更新"] {
            let quote = verb + "紅茶"
            let review = try searched(state, [quote]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: "紅茶"))
            try c.expect(review.op == .update && review.after?.content == "紅茶", "Traditional update intent \(verb)")
            for prefix in ["不要", "別", "無需", "無須", "禁止"] {
                let run = try searched(state, [prefix + quote])
                try c.rejects(.editNotRequested) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: "紅茶")) }
            }
        }
        for verb in ["刪除", "刪掉", "忘記", "取消記憶", "別記", "不要記"] {
            let quote = verb + "綠茶"
            for prefix in ["不要", "別", "無需", "無須", "禁止"] {
                let run = try searched(state, [prefix + quote])
                try c.rejects(.editNotRequested) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote)) }
            }
        }
        let fullMessage = "請刪除綠茶。但不要刪除綠茶，我還在考慮。"
        let run = try searched(state, [fullMessage])
        try c.rejects(.editNotRequested) { _ = try run.prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "請刪除綠茶")) }
        return c.count
    }

    static func updateDeleteLifecycle() throws -> Int {
        var c = Check(), state = try single(.procedure)
        let id = state.memories[0].id
        try state.approve(id: id)
        try state.setPinned(id: id, pinned: true)
        try state.markUsed([id], now: now)
        let original = state.memories[0], quote = "Update Black tea"
        let review = try searched(state, [quote]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: "Black tea"))
        try c.expect(review.before?.status == .active && review.after?.status == .pending && review.keywords == ["tea"], "Omitted keywords preserved; procedure update needs approval")
        let receipt = try review.apply(to: &state, conversationID: "run-A", now: now.addingTimeInterval(1))
        let item = state.memories[0]
        try c.expect(item.id == id && item.kind == .procedure && item.replaces == "Green tea" && item.source.type == "user_said", "Update retains ID/kind and replaces history")
        try c.expect(item.pinned && item.useCount == 1 && item.createdAt == original.createdAt, "Update retains pin/use/creation")
        try c.expect(receipt.op == "update" && receipt.note.kind == .pending && receipt.note.pendingID == id, "Update pending note")
        let fields = try object(receipt.resultJSON())
        try c.expect(Set(fields.keys) == ["ok", "op", "id", "kind", "status"] && fields["status"] as? String == "pending", "Pinned update JSON")
        let restored = try state.undo(token: receipt.note.undoToken!)
        try c.expect(restored && state.memories[0] == original, "Undo restores approved predecessor exactly")
        let clearWords = try searched(state, [quote]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: quote, content: "Black tea", keywords: []))
        _ = try clearWords.apply(to: &state, now: now)
        try c.expect(state.memories[0].keywords.isEmpty, "Explicit empty keywords clears old keywords")
        try state.approve(id: id)
        let deletion = try searched(state, ["Delete Black tea"], query: "Black tea").prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "Delete Black tea"))
        try c.expect(deletion.before?.content == "Black tea" && deletion.after == nil && deletion.keywords == nil, "Delete preview")
        let beforeDelete = state.memories[0]
        let deleted = try deletion.apply(to: &state, now: now)
        try c.expect(state.memories.isEmpty && deleted.note.kind == .forgot && deleted.note.pendingID == nil, "Delete commits host undo note")
        let deletedJSON = try object(deleted.resultJSON())
        try c.expect(Set(deletedJSON.keys) == ["ok", "op", "id", "deleted"] && deletedJSON["deleted"] as? Bool == true, "Pinned delete JSON excludes obsolete kind/status")
        let undone = try state.undo(token: deleted.note.undoToken!)
        try c.expect(undone && state.memories == [beforeDelete], "Delete undo restores entire row")
        return c.count
    }

    static func transactionsAndSafety() throws -> Int {
        var c = Check(), state = try single()
        let original = state, id = state.memories[0].id
        let review = try MemoryToolRun(state: state, utterances: ["Remember Coffee"]).prepare(toolName: "memory_save", argumentsJSON: save("Coffee", quote: "Remember Coffee"))
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            try c.rejectsState(.invalidState) { _ = try review.apply(to: &state, now: date) }
            try c.expect(state == original, "Invalid clock rolls back all published fields")
        }
        try c.rejectsState(.invalidState) { _ = try review.apply(to: &state, conversationID: String(repeating: "😀", count: 129), now: now) }
        try c.expect(state == original, "Invalid source metadata rolls back")
        var discarded = state
        _ = try review.apply(to: &discarded, now: now)
        try c.expect(state == original && discarded.memories.count == 2, "Host may discard applied copy after persistence failure")
        for mutate: (inout MemoryState) throws -> Void in [
            { try $0.markUsed([id], now: now) }, { try $0.setPinned(id: id, pinned: true) },
            { $0.clearAll() }, { $0.setPreferences(.init(autoRemember: false)) },
            { try $0.add(kind: .fact, content: "Other", now: now) }] {
            var changed = original; try mutate(&changed); let snapshot = changed
            try c.rejects(.staleRevision) { _ = try review.apply(to: &changed, now: now) }
            try c.expect(changed == snapshot, "Stale revision cannot overwrite concurrent state")
        }
        state.setPreferences(.init(useMemory: false))
        let off = state
        try c.rejects(.disabled) { _ = try review.apply(to: &state, now: now) }
        try c.expect(state == off, "Master off blocks outstanding review")
        state = original
        for (content, quote, keywords) in [
            ("password: dummy1234", "Remember password: dummy1234", [String]()),
            ("Tea", "Remember Tea password: dummy1234", []),
            ("Tea", "Remember Tea password: dummy1234", ["password: dummy1234"])] {
            try c.rejectsState(.sensitiveContent) {
                _ = try MemoryToolRun(state: state, utterances: [quote]).prepare(toolName: "memory_save", argumentsJSON: save(content, quote: quote, keywords: keywords))
            }
        }
        try c.rejectsState(.duplicate) { _ = try MemoryToolRun(state: state, utterances: ["Remember Green tea"]).prepare(toolName: "memory_save", argumentsJSON: save("Green tea", quote: "Remember Green tea")) }
        var full = MemoryState()
        for index in 0..<500 { try full.add(kind: .fact, content: "Entry \(index)", now: now) }
        let fullBefore = full
        try c.rejectsState(.capacityExceeded) { _ = try MemoryToolRun(state: full, utterances: ["Remember extra"]).prepare(toolName: "memory_save", argumentsJSON: save("extra", quote: "Remember extra")) }
        try c.expect(full == fullBefore && full.memories.count == 500, "Capacity rejection never evicts")
        return c.count
    }

    static func undoBoundary() throws -> Int {
        var c = Check(), state = MemoryState(), tokens: [UUID] = []
        for index in 0..<51 {
            let content = "Entry \(index)", quote = "Remember Entry \(index)"
            let review = try MemoryToolRun(state: state, utterances: [quote]).prepare(toolName: "memory_save", argumentsJSON: save(content, quote: quote))
            let receipt = try review.apply(to: &state, now: now)
            tokens.append(receipt.note.undoToken!)
        }
        let oldest = try state.undo(token: tokens[0])
        try c.expect(!oldest && state.memories.count == 51, "Only last fifty undo records retained")
        var restored = try JSONDecoder().decode(MemoryState.self, from: JSONEncoder().encode(state))
        let relaunched = try restored.undo(token: tokens[50])
        try c.expect(!relaunched && restored == state, "Undo is RAM only across relaunch")
        let last = try state.undo(token: tokens[50]), replay = try state.undo(token: tokens[50])
        try c.expect(last && !replay && state.memories.count == 50, "Undo consumed exactly once")
        let oldestRetained = try state.undo(token: tokens[1])
        try c.expect(oldestRetained && state.memories.count == 49, "Fiftieth newest record remains undoable")
        var procedure = MemoryState()
        let proposal = try MemoryToolRun(state: procedure, utterances: ["Remember Tea"]).prepare(toolName: "memory_save", argumentsJSON: save("Tea", quote: "Remember Tea", kind: .procedure))
        let pending = try proposal.apply(to: &procedure, now: now)
        try procedure.approve(id: pending.id)
        let late = try procedure.undo(token: pending.note.undoToken!)
        try c.expect(!late && procedure.memories[0].status == .active, "Late undo cannot silently remove later-approved procedure")
        var update = try single()
        let id = update.memories[0].id
        let replacement = try searched(update, ["Update Black tea"]).prepare(toolName: "memory_edit", argumentsJSON: edit(id, quote: "Update Black tea", content: "Black tea"))
        let changed = try replacement.apply(to: &update, now: now)
        try update.setPinned(id: id, pinned: true); try update.markUsed([id], now: now)
        let undo = try update.undo(token: changed.note.undoToken!)
        try c.expect(undo && update.memories[0].content == "Green tea" && update.memories[0].pinned && update.memories[0].useCount == 1, "Undo preserves later pin/use bookkeeping")
        return c.count
    }

    static func undoEligibility() throws -> Int {
        var c = Check(), state = try single()
        let id = state.memories[0].id, item = state.memories[0]
        let review = try searched(state, ["Delete Green tea"]).prepare(toolName: "memory_edit",
            argumentsJSON: edit(id, quote: "Delete Green tea"))
        let deleted = try review.apply(to: &state, now: now), token = deleted.note.undoToken!
        let beforePreferences = state
        try c.expect(state.canUndo(token: token) && state.canUndo(token: token), "Repeated queries do not consume a deletion token")
        try c.expect(state == beforePreferences && state.memories.isEmpty, "Eligible query changes neither values nor revision")
        state.setPreferences(.init(useMemory: false, autoRemember: false))
        let changedPreferences = state
        try c.expect(state.canUndo(token: token), "Deleted memory remains undoable after master/auto preference changes")
        try c.expect(state == changedPreferences, "Preference-change eligibility is read-only")
        let restored = try state.undo(token: token)
        try c.expect(restored && state.memories == [item] && state.preferences == changedPreferences.preferences,
                     "Real undo still restores exact row without reverting preferences")
        let afterUndo = state
        try c.expect(!state.canUndo(token: token) && !state.canUndo(token: UUID()), "Consumed and unknown tokens are ineligible")
        try c.expect(state == afterUndo, "Ineligible query leaves state unchanged")

        let editNote = try state.edit(id: id, content: "Black tea", now: now.addingTimeInterval(1))
        let later = try state.edit(id: id, content: "White tea", now: now.addingTimeInterval(2))
        let latest = state
        try c.expect(!state.canUndo(token: editNote.undoToken!), "Later content edit makes earlier undo stale")
        try c.expect(state.canUndo(token: later.undoToken!) && state == latest, "Stale query does not disturb latest undo")
        let reverted = try state.undo(token: later.undoToken!)
        try c.expect(reverted && state.canUndo(token: editNote.undoToken!), "Real newer undo restores eligibility of older change")

        var procedure = MemoryState()
        let pending = try procedure.add(kind: .procedure, content: "Tea routine", now: now)
        try c.expect(procedure.canUndo(token: pending.undoToken!), "Pending add is undoable before approval")
        try procedure.approve(id: pending.memoryID)
        let approved = procedure
        try c.expect(!procedure.canUndo(token: pending.undoToken!) && procedure == approved, "Read-only query respects later procedure approval")

        var duplicate = try single()
        let old = duplicate.memories[0], deletion = try duplicate.delete(id: old.id)
        let replacement = try duplicate.add(kind: old.kind, content: old.content, now: now)
        let duplicateBefore = duplicate
        try c.expect(!duplicate.canUndo(token: deletion.undoToken!) && duplicate == duplicateBefore, "Duplicate restore rejection is read-only")
        try c.rejectsState(.duplicate) { _ = try duplicate.undo(token: deletion.undoToken!) }
        _ = try duplicate.delete(id: replacement.memoryID)
        try c.expect(duplicate.canUndo(token: deletion.undoToken!), "Removing duplicate restores eligibility without consuming original token")
        let recovered = try duplicate.undo(token: deletion.undoToken!)
        try c.expect(recovered && duplicate.memories == [old], "Original deletion can still be restored after duplicate rejection")

        var full = MemoryState()
        for index in 0..<500 { try full.add(kind: .fact, content: "Entry \(index)", now: now) }
        let removed = full.memories[0], capacityNote = try full.delete(id: removed.id)
        let extra = try full.add(kind: .fact, content: "Extra", now: now)
        let fullBefore = full
        try c.expect(!full.canUndo(token: capacityNote.undoToken!) && full == fullBefore, "Full-capacity restore rejection is read-only")
        try c.rejectsState(.capacityExceeded) { _ = try full.undo(token: capacityNote.undoToken!) }
        _ = try full.delete(id: extra.memoryID)
        try c.expect(full.canUndo(token: capacityNote.undoToken!), "Freeing capacity restores eligibility of same token")
        let recoveredFull = try full.undo(token: capacityNote.undoToken!)
        try c.expect(recoveredFull && full.memories.count == 500 && full.memories.contains(removed), "Capacity checks did not consume or damage undo")

        var retained = MemoryState(), tokens: [UUID] = []
        for index in 0..<51 { tokens.append(try retained.add(kind: .fact, content: "Record \(index)", now: now).undoToken!) }
        let retentionSnapshot = retained
        try c.expect(!retained.canUndo(token: tokens[0]) && retained.canUndo(token: tokens[1]), "Eligibility observes exact fifty-token retention")
        try c.expect(retained == retentionSnapshot, "Retention queries do not mutate state")
        let decoded = try JSONDecoder().decode(MemoryState.self, from: JSONEncoder().encode(retained))
        try c.expect(!decoded.canUndo(token: tokens[50]) && decoded == retained, "Relaunched state has no undo authority despite identical persisted values")
        retained.clearAll()
        let cleared = retained
        try c.expect(!retained.canUndo(token: tokens[50]) && retained == cleared, "Clear invalidates undo without query side effects")
        return c.count
    }
}

#if MEMORY_TOOLS_STANDALONE
@main enum CheckMemoryTools {
    static func main() {
        do {
            var total = 0
            for (name, run) in [("strict arguments", MemoryToolChecks.strictArguments),
                                ("search proof", MemoryToolChecks.searchProof),
                                ("provenance/specifics", MemoryToolChecks.provenanceAndSpecifics),
                                ("add/receipt", MemoryToolChecks.addAndReceipt),
                                ("edit proof/intent", MemoryToolChecks.editProofAndIntent),
                                ("Traditional Chinese intent", MemoryToolChecks.traditionalIntent),
                                ("update/delete", MemoryToolChecks.updateDeleteLifecycle),
                                ("transaction/safety", MemoryToolChecks.transactionsAndSafety),
                                ("undo", MemoryToolChecks.undoBoundary),
                                ("undo eligibility", MemoryToolChecks.undoEligibility)] {
                let count = try run(); total += count; print("\(name): \(count)")
            }
            print("PASS \(total) memory tool assertions; no network or persistence")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
#else
final class MemoryToolsTests: XCTestCase {
    func testStrictArguments() throws { XCTAssertGreaterThan(try MemoryToolChecks.strictArguments(), 0) }
    func testSearchProofAndMasterGate() throws { XCTAssertGreaterThan(try MemoryToolChecks.searchProof(), 0) }
    func testOnlyCurrentUserProvenanceAndSpecifics() throws { XCTAssertGreaterThan(try MemoryToolChecks.provenanceAndSpecifics(), 0) }
    func testReviewedSaveAndReceipt() throws { XCTAssertGreaterThan(try MemoryToolChecks.addAndReceipt(), 0) }
    func testLatestCandidateAndWholeMessageIntent() throws { XCTAssertGreaterThan(try MemoryToolChecks.editProofAndIntent(), 0) }
    func testTraditionalChineseIntentAndNegation() throws { XCTAssertGreaterThan(try MemoryToolChecks.traditionalIntent(), 0) }
    func testUpdateDeleteProcedureAndUndo() throws { XCTAssertGreaterThan(try MemoryToolChecks.updateDeleteLifecycle(), 0) }
    func testStaleAndTransactionalSafety() throws { XCTAssertGreaterThan(try MemoryToolChecks.transactionsAndSafety(), 0) }
    func testUndoRetentionAndRelaunchBoundary() throws { XCTAssertGreaterThan(try MemoryToolChecks.undoBoundary(), 0) }
    func testReadOnlyUndoEligibilityAndDeleteAfterPreferences() throws { XCTAssertGreaterThan(try MemoryToolChecks.undoEligibility(), 0) }
}
#endif
