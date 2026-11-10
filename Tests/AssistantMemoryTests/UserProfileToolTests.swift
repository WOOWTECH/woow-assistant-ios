import Foundation
import AssistantMemory
#if !USER_PROFILE_TOOL_STANDALONE
import XCTest
#endif

enum UserProfileToolChecks {
    struct Failure: Error { let name: String }
    struct Check {
        var count = 0
        mutating func expect(_ value: @autoclosure () -> Bool, _ name: String) throws {
            count += 1
            if !value() { throw Failure(name: name) }
        }
        mutating func rejects(_ expected: UserProfileToolError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(name: "Expected \(expected.rawValue)") }
            catch let error as UserProfileToolError { try expect(error == expected, "Tool error category") }
        }
        mutating func rejectsState(_ expected: UserProfileError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(name: "Expected \(expected.rawValue)") }
            catch let error as UserProfileError { try expect(error == expected, "State error category") }
        }
    }
    static let now = Date(timeIntervalSince1970: 1234)

    static func arguments(_ op: String = "add", text: String? = nil, match: String? = nil, quote: String) throws -> String {
        var fields = ["op": op, "quote": quote]
        fields["text"] = text; fields["match"] = match
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }
    static func request(_ op: String = "add", text: String? = nil, match: String? = nil, quote: String) throws -> UserProfileToolRequest {
        try .parse(arguments(op, text: text, match: match, quote: quote))
    }

    static func strictArguments() throws -> Int {
        var c = Check()
        let valid = try arguments(text: "Tea", quote: "Remember Tea")
        let parsed = try UserProfileToolRequest.parse(" \n" + valid + "\t")
        try c.expect(parsed.op == .add && parsed.text == "Tea" && parsed.match == nil && parsed.quote == "Remember Tea", "Exact argument values")
        let invalid = ["", "null", "[]", "{}", "prefix " + valid, valid + " trailing", "```json\n" + valid + "\n```",
            #"{"op":"add","text":"Tea"}"#,
            #"{"op":"add","quote":"Remember Tea"}"#,
            #"{"op":"replace","text":"Tea","quote":"Remember Tea"}"#,
            #"{"op":"delete","quote":"Delete Tea"}"#,
            #"{"op":"ADD","text":"Tea","quote":"Remember Tea"}"#,
            #"{"op":"add","text":true,"quote":"Remember Tea"}"#,
            #"{"op":"add","text":4,"quote":"Remember Tea"}"#,
            #"{"op":"add","text":[],"quote":"Remember Tea"}"#,
            #"{"op":"add","text":"Tea","quote":null}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea","utterances":"Remember Tea"}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea","approved":true}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea","source":"user"}"#,
            #"{"op":"add","op":"delete","text":"Tea","quote":"Remember Tea"}"#,
            #"{"op":"add","\u006fp":"add","text":"Tea","quote":"Remember Tea"}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea","quote":"Other"}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea","match":null,"match":null}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea",}"#,
            #"{"op":"add","text":"Tea","quote":"Remember Tea"}{}"#,
            #"{"op":"add","text":"\uD800","quote":"Remember Tea"}"#,
            #"{"op":"add","text":"\q","quote":"Remember Tea"}"#]
        for raw in invalid { try c.rejects(.invalidArguments) { _ = try UserProfileToolRequest.parse(raw) } }
        for value in ["", " \n", String(repeating: "😀", count: 81)] {
            try c.rejects(.invalidArguments) { _ = try request(text: value, quote: "Remember Tea") }
            try c.rejects(.invalidArguments) { _ = try request("delete", match: value, quote: "Delete Tea") }
        }
        try c.rejects(.invalidArguments) { _ = try request(text: "Tea", quote: String(repeating: "😀", count: 501)) }
        let boundary = try request(text: String(repeating: "😀", count: 80), quote: String(repeating: "字", count: 1000))
        try c.expect(boundary.text?.utf16.count == 160 && boundary.quote.utf16.count == 1000, "UTF16 inclusive argument limits")
        let null = try UserProfileToolRequest.parse(#"{"op":"add","text":"Tea","match":null,"quote":"Remember Tea"}"#)
        try c.expect(null.match == nil, "Pinned optional null is absent")
        let escaped = try request(text: "Use \"Tea\"", quote: "Please record Use \"Tea\"")
        try c.expect(escaped.text == "Use \"Tea\"", "Escaped string content is preserved")
        return c.count
    }

    static func currentUserProvenance() throws -> Int {
        var c = Check(), state = UserProfileState()
        try state.add(text: "Saved page says cobalt", now: now)
        let original = state
        for quote in ["Website says cobalt", "Assistant suggested cobalt", "Yesterday I said cobalt", "Saved page says cobalt"] {
            let proposal = try request(text: "cobalt", quote: quote)
            try c.rejects(.quoteNotFromUser) { _ = try proposal.prepare(state: state, utterances: ["Please inspect my profile"]) }
        }
        try c.rejects(.quoteNotFromUser) {
            _ = try request(text: "Tea", quote: "Remember Tea").prepare(state: state, utterances: [])
        }
        try c.rejects(.quoteNotFromUser) {
            _ = try request(text: "Tea", quote: "T").prepare(state: state, utterances: ["Tea"])
        }
        try c.rejects(.quoteNotFromUser) {
            _ = try request(text: "Tea", quote: "remember tea").prepare(state: state, utterances: ["Remember Tea"])
        }
        let compatibility = try request(text: "Tea", quote: "  Remember Tea  ")
            .prepare(state: state, utterances: ["Ｒｅｍｅｍｂｅｒ Ｔｅａ"])
        try c.expect(compatibility.quote == "  Remember Tea  " && compatibility.after == "Tea", "NFKC membership preserves original quote")
        let emoji = try request(text: "😀", quote: "😀").prepare(state: state, utterances: ["😀"])
        try c.expect(emoji.after == "😀", "Minimum quote uses UTF16 units")
        _ = try request("delete", match: "cobalt", quote: "Do not delete cobalt")
            .prepare(state: state, utterances: ["Do not delete cobalt"])
        try c.expect(state == original, "Quote membership only prepares; it never infers intent or automatically mutates")
        return c.count
    }

    static func specificValues() throws -> Int {
        var c = Check()
        let accepted: [(String, String)] = [
            ("编号1234567", "记住我的编号一二三四五六七"),
            ("编号1234567", "记住编号１２３ ４５６７"),
            ("编号1234567", "编号1-234.567"),
            ("编号12", "编号一百二"),
            ("用户的名字是「王小明」", "我的名字是「王小明」"),
            ("住在张江路100号", "我的地址张江路１００号"),
            ("TEA", "Remember tea")]
        for (text, quote) in accepted {
            let result = try request(text: text, quote: quote).prepare(state: UserProfileState(), utterances: [quote])
            try c.expect(result.after == text, "Grounding normalization does not rewrite saved content")
        }
        for (text, quote) in [("编号7654321", "编号1234567"), ("编号12", "编号1-2"),
                              ("叫「王大明」", "叫「王小明」"), ("住在紫荆路", "住在张江路"),
                              ("coffee", "Remember tea"), ("User prefers tea", "Remember tea")] {
            try c.rejects(.contentNotFromUser) {
                _ = try request(text: text, quote: quote).prepare(state: UserProfileState(), utterances: [quote])
            }
        }
        let fromAnotherCurrentUtterance = try request(text: "cobalt", quote: "Please remember my color")
            .prepare(state: UserProfileState(), utterances: ["My color is cobalt", "Please remember my color"])
        try c.expect(fromAnotherCurrentUtterance.after == "cobalt", "Pinned specifics use all current user utterances")
        return c.count
    }

    static func reviewedLifecycle() throws -> Int {
        var c = Check(), state = UserProfileState()
        let empty = state, snapshot = state.snapshot()
        let add = try request(text: "Prefer green tea", quote: "Remember Prefer green tea")
            .prepare(state: state, utterances: ["Remember Prefer green tea"])
        try c.expect(state == empty && add.baseRevision == state.revision, "Prepare does not mutate state or revision")
        try c.expect(add.op == .add && add.before == nil && add.after == "Prefer green tea", "Add review displays full proposed text")
        let first = try add.apply(to: &state, now: now)
        try c.expect(first.applied && first.effective == "next_run" && first.id == state.entries[0].id, "Committed value receipt")
        try c.expect(state.entries[0].createdAt == now && state.revision != empty.revision, "Apply uses approval time and creates revision")
        try c.expect(snapshot.entries.isEmpty && snapshot.message == nil, "Original context stays frozen")
        let firstID = state.entries[0].id, saved = state
        let replacement = try request("replace", text: "black", match: "green", quote: "Replace green with black")
            .prepare(state: state, utterances: ["Replace green with black"])
        try c.expect(replacement.before == "Prefer green tea" && replacement.after == "Prefer black tea", "Review shows complete sentence after fragment replacement")
        try c.expect(state == saved, "Replacement prepare remains pure")
        let replaced = try replacement.apply(to: &state, now: now.addingTimeInterval(1))
        try c.expect(replaced.id != firstID && replaced.id == state.snapshot().entries[0].id, "Replacement creates new entry ID")
        try c.expect(state.entries[0].status == .superseded && state.entries[0].supersededAt == now.addingTimeInterval(1), "Replacement retains exact history")
        let deletion = try request("delete", match: "black", quote: "Delete black tea")
            .prepare(state: state, utterances: ["Delete black tea"])
        try c.expect(deletion.before == "Prefer black tea" && deletion.after == nil, "Delete review identifies whole row")
        let deleted = try deletion.apply(to: &state, now: now.addingTimeInterval(2))
        try c.expect(deleted.applied && deleted.id == nil && deleted.effective == "next_run", "Delete receipt has no new entry")
        try c.expect(state.snapshot().entries.isEmpty && state.entries.count == 2, "Delete keeps both historical entries")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(deleted)) as! [String: Any]
        try c.expect(Set(object.keys) == ["applied", "effective"], "Nil receipt ID omitted from JSON")
        let decoded = try JSONDecoder().decode(UserProfileState.self, from: JSONEncoder().encode(state))
        try c.expect(decoded == state, "Result preserves valid persistence state")
        return c.count
    }

    static func stateRules() throws -> Int {
        var c = Check(), state = UserProfileState()
        try state.add(text: "banana", now: now)
        for segment in ["ana", "missing"] {
            try c.rejectsState(.matchNotUnique) {
                _ = try request("delete", match: segment, quote: "Delete " + segment).prepare(state: state, utterances: ["Delete " + segment])
            }
        }
        try state.add(text: "banana split", now: now)
        try c.rejectsState(.matchNotUnique) {
            _ = try request("delete", match: "banana", quote: "Delete banana").prepare(state: state, utterances: ["Delete banana"])
        }
        for text in ["password: dummy1234", "Two. Sentences.", "A\r\nB"] {
            try c.rejectsState(.invalidSentence) {
                _ = try request(text: text, quote: text).prepare(state: state, utterances: [text])
            }
        }
        try c.rejectsState(.duplicate) {
            _ = try request(text: "banana", quote: "Remember banana").prepare(state: state, utterances: ["Remember banana"])
        }
        var unicode = UserProfileState()
        try unicode.add(text: "café", now: now)
        try c.rejectsState(.matchNotUnique) {
            _ = try request("delete", match: "cafe\u{301}", quote: "Delete cafe\u{301}")
                .prepare(state: unicode, utterances: ["Delete café"])
        }
        var full = UserProfileState()
        for index in 0..<20 { try full.add(text: "Entry \(index)", now: now) }
        let original = full
        try c.rejectsState(.profileFull) {
            _ = try request(text: "Extra", quote: "Remember Extra").prepare(state: full, utterances: ["Remember Extra"])
        }
        try c.expect(full == original, "Rejected full profile never evicts rows")
        let replacement = try request("replace", text: "Replacement", match: "Entry 19", quote: "Replace Entry 19 with Replacement")
            .prepare(state: full, utterances: ["Replace Entry 19 with Replacement"])
        _ = try replacement.apply(to: &full, now: now)
        try c.expect(full.snapshot().entries.count == 20 && full.entries.count == 21, "Replace at capacity is permitted")
        var joined = UserProfileState()
        try joined.add(text: "prefix " + String(repeating: "字", count: 153), now: now)
        try c.rejectsState(.invalidSentence) {
            _ = try request("replace", text: "longerword", match: "prefix", quote: "Replace prefix with longerword")
                .prepare(state: joined, utterances: ["Replace prefix with longerword"])
        }
        return c.count
    }

    static func staleAndTransactional() throws -> Int {
        var c = Check(), state = UserProfileState()
        let review = try request(text: "Tea", quote: "Remember Tea").prepare(state: state, utterances: ["Remember Tea"])
        let original = state
        try c.rejectsState(.invalidState) { _ = try review.apply(to: &state, now: Date(timeIntervalSince1970: .nan)) }
        try c.expect(state == original, "Bad approval clock leaves every state field unchanged")
        var persistedCandidate = state
        _ = try review.apply(to: &persistedCandidate, now: now)
        try c.expect(state == original && !persistedCandidate.entries.isEmpty, "Host can discard candidate on persistence failure")
        _ = try state.add(text: "Concurrent edit", now: now)
        let changed = state
        try c.rejects(.staleRevision) { _ = try review.apply(to: &state, now: now) }
        try c.expect(state == changed, "Stale review cannot overwrite concurrent changes")
        state = original
        _ = try review.apply(to: &state, now: now)
        let applied = state
        try c.rejects(.staleRevision) { _ = try review.apply(to: &state, now: now) }
        try c.expect(state == applied, "A review cannot replay after application")
        let beforeClear = try request("delete", match: "Tea", quote: "Delete Tea").prepare(state: state, utterances: ["Delete Tea"])
        state = UserProfileState()
        let cleared = state
        try c.rejects(.staleRevision) { _ = try beforeClear.apply(to: &state, now: now) }
        try c.expect(state == cleared, "Review prepared before clear cannot repopulate data")
        return c.count
    }
}

#if USER_PROFILE_TOOL_STANDALONE
@main enum CheckUserProfileTool {
    static func main() {
        do {
            var total = 0
            for (name, run) in [("strict arguments", UserProfileToolChecks.strictArguments),
                                ("current-user provenance", UserProfileToolChecks.currentUserProvenance),
                                ("specific values", UserProfileToolChecks.specificValues),
                                ("reviewed lifecycle", UserProfileToolChecks.reviewedLifecycle),
                                ("state rules", UserProfileToolChecks.stateRules),
                                ("stale/transactional", UserProfileToolChecks.staleAndTransactional)] {
                let count = try run(); total += count; print("\(name): \(count)")
            }
            print("PASS \(total) profile tool assertions; no network or persistence")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
#else
final class UserProfileToolTests: XCTestCase {
    func testStrictArguments() throws { XCTAssertGreaterThan(try UserProfileToolChecks.strictArguments(), 0) }
    func testOnlyCurrentUserProvenance() throws { XCTAssertGreaterThan(try UserProfileToolChecks.currentUserProvenance(), 0) }
    func testSpecificValuesAndNormalization() throws { XCTAssertGreaterThan(try UserProfileToolChecks.specificValues(), 0) }
    func testReviewedAddReplaceDeleteAndReceipt() throws { XCTAssertGreaterThan(try UserProfileToolChecks.reviewedLifecycle(), 0) }
    func testStateRulesStillApply() throws { XCTAssertGreaterThan(try UserProfileToolChecks.stateRules(), 0) }
    func testStaleAndTransactionalApplication() throws { XCTAssertGreaterThan(try UserProfileToolChecks.staleAndTransactional(), 0) }
}
#endif
