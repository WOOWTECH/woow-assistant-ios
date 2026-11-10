import Foundation
#if !CHAT_CONTEXT_WINDOW_STANDALONE
import XCTest
@testable import AssistantModels
#endif

enum ChatContextWindowChecks {
    struct Failure: Error { let message: String }
    struct Check {
        var count = 0
        mutating func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(message: message) }
            count += 1
        }
        mutating func rejects(_ expected: ChatContextWindowError, _ action: () throws -> Void) throws {
            do { try action(); throw Failure(message: "Expected window rejection") }
            catch let actual as ChatContextWindowError { try expect(actual == expected, "Exact rejection category") }
        }
    }
    static func pair(_ user: String, _ assistant: String) -> [ModelMessage] {
        [.init(role: "user", content: user), .init(role: "assistant", content: assistant)]
    }
    static func history(_ count: Int) -> [ModelMessage] {
        (0..<count).flatMap { pair("user-\($0)", "assistant-\($0)") }
    }
    static func bytes(_ messages: [ModelMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.utf8.count }
    }

    static func longConversation() throws -> Int {
        var check = Check()
        let original = history(40)
        let context = [ModelMessage(role: "user", content: "完整個人檔案參考")]
        let window = try ChatContextWindow(history: original, context: context, prompt: "本輪原文")
        try check.expect(window.retainedTurns == 15 && window.omittedTurns == 25, "Forty turns retain the latest fifteen")
        try check.expect(window.messages.count == 32, "Exact message limit")
        try check.expect(window.messages.first == original[50], "First retained user is turn twenty-five")
        try check.expect(Array(window.messages.prefix(30)) == Array(original.suffix(30)), "Complete recent turns remain in chronological order")
        try check.expect(Array(window.messages.suffix(2)) == context + [.init(role: "user", content: "本輪原文")], "Complete current context and prompt remain last")
        try check.expect(original == history(40), "Original forty-turn history unchanged")
        try check.expect(context[0].content == "完整個人檔案參考", "Original context unchanged")

        let seventeen = try ChatContextWindow(history: history(17), context: [], prompt: "next")
        try check.expect(seventeen.retainedTurns == 15 && seventeen.omittedTurns == 2, "Conversation continues beyond seventeen turns")
        try check.expect(seventeen.messages.count == 31, "One spare slot cannot contain half a turn")
        let short = try ChatContextWindow(history: history(2), context: context, prompt: "next")
        try check.expect(short.retainedTurns == 2 && short.omittedTurns == 0, "Short conversation remains complete")
        try check.expect(Array(short.messages.prefix(4)) == history(2), "Short history order unchanged")
        let empty = try ChatContextWindow(history: [], context: [], prompt: "hello")
        try check.expect(empty.messages == [.init(role: "user", content: "hello")], "First turn needs no history")
        try check.expect(empty.retainedTurns == 0 && empty.omittedTurns == 0, "First-turn counts")
        return check.count
    }

    static func utf8AndExactCurrentTurn() throws -> Int {
        var check = Check()
        let context = [ModelMessage(role: "user", content: String(repeating: "茶", count: 21844))]
        let exact = try ChatContextWindow(history: history(1), context: context, prompt: "😀")
        try check.expect(bytes(exact.messages) == 65536, "Three- and four-byte characters exactly fill the UTF8 budget")
        try check.expect(exact.retainedTurns == 0 && exact.omittedTurns == 1, "Current context has priority over history")
        try check.expect(exact.messages[0].content.utf8.elementsEqual(context[0].content.utf8), "Current reference bytes are not clipped")
        try check.expect(exact.messages[1].content == "😀", "Entire emoji prompt remains")
        try check.rejects(.currentTurnTooLarge) { _ = try ChatContextWindow(history: [], context: context, prompt: "😀x") }

        let decomposed = "Cafe\u{301}\n甲", composed = "Café\n乙"
        let distinct = try ChatContextWindow(history: pair(decomposed, composed),
            context: [.init(role: "user", content: decomposed)], prompt: composed)
        try check.expect(distinct.messages[0].content.utf8.elementsEqual(decomposed.utf8), "History normalization is not changed")
        try check.expect(distinct.messages[2].content.utf8.elementsEqual(decomposed.utf8), "Context normalization is not changed")
        try check.expect(distinct.messages[3].content.utf8.elementsEqual(composed.utf8), "Prompt bytes remain exact")

        let largeUser = String(repeating: "茶", count: 10922)
        let largeAssistant = String(repeating: "😀", count: 8191) + "b"
        let original = pair("a", "b") + pair(largeUser, largeAssistant)
        let retained = try ChatContextWindow(history: original, context: [.init(role: "user", content: "x")], prompt: "😀")
        try check.expect(bytes(retained.messages) == 65536, "A complete multibyte history pair exactly fits")
        try check.expect(retained.retainedTurns == 1 && retained.omittedTurns == 1, "Older pair is excluded by UTF8 bytes")
        try check.expect(retained.messages[0].content == largeUser && retained.messages[1].content == largeAssistant, "Large pair retained without splitting")
        try check.expect(original.count == 4 && original[0].content == "a", "Original history retained outside the window")
        return check.count
    }

    static func contiguousSuffix() throws -> Int {
        var check = Check()
        let enormous = String(repeating: "茶", count: 21846)
        let original = pair("old-user", "old-answer") + pair(enormous, "latest-answer")
        let window = try ChatContextWindow(history: original, context: [], prompt: "current")
        try check.expect(window.retainedTurns == 0 && window.omittedTurns == 2, "Oversized newest user prevents older turns being selected")
        try check.expect(window.messages == [.init(role: "user", content: "current")], "No older turn can leap over the newest oversized pair")
        let assistantTooLarge = try ChatContextWindow(history: pair("old", "old") + pair("new", enormous), context: [], prompt: "current")
        try check.expect(assistantTooLarge.retainedTurns == 0 && assistantTooLarge.omittedTurns == 2, "Oversized newest assistant also excludes the whole pair")
        let withNewer = try ChatContextWindow(history: original + pair("newer-user", "newer-answer"), context: [], prompt: "current")
        try check.expect(withNewer.retainedTurns == 1 && withNewer.omittedTurns == 2, "Retain recent pair then stop at oversized middle pair")
        try check.expect(withNewer.messages == pair("newer-user", "newer-answer") + [.init(role: "user", content: "current")], "No discontinuous old-history substitution")
        try check.expect(original[2].content.utf8.elementsEqual(enormous.utf8), "Oversized original remains unchanged")
        return check.count
    }

    static func currentLimits() throws -> Int {
        var check = Check()
        let thirtyOne = (0..<31).map { ModelMessage(role: "user", content: "context-\($0)") }
        let exact = try ChatContextWindow(history: history(2), context: thirtyOne, prompt: "current")
        try check.expect(exact.messages.count == 32 && exact.retainedTurns == 0 && exact.omittedTurns == 2, "Current turn can consume all thirty-two slots")
        try check.expect(Array(exact.messages.prefix(31)) == thirtyOne, "All current context messages preserved")
        let odd = try ChatContextWindow(history: history(2), context: Array(thirtyOne.dropLast()), prompt: "current")
        try check.expect(odd.messages.count == 31 && odd.retainedTurns == 0, "One remaining slot cannot split a history pair")
        try check.rejects(.currentTurnTooLarge) {
            _ = try ChatContextWindow(history: [], context: thirtyOne + [.init(role: "user", content: "last")], prompt: "current")
        }
        let asciiLimit = String(repeating: "x", count: 65536)
        let exactPrompt = try ChatContextWindow(history: [], context: [], prompt: asciiLimit)
        try check.expect(exactPrompt.messages[0].content == asciiLimit, "Exact byte limit prompt accepted unchanged")
        try check.rejects(.currentTurnTooLarge) { _ = try ChatContextWindow(history: [], context: [], prompt: asciiLimit + "x") }
        try check.rejects(.currentTurnTooLarge) {
            _ = try ChatContextWindow(history: [], context: [.init(role: "user", content: asciiLimit)], prompt: "x")
        }
        try check.rejects(.currentTurnTooLarge) {
            _ = try ChatContextWindow(history: [], context: [.init(role: "user", content: asciiLimit + "x")], prompt: "")
        }
        try check.expect(thirtyOne.count == 31 && asciiLimit.utf8.count == 65536, "Rejected current inputs remain unchanged")
        return check.count
    }

    static func malformedHistory() throws -> Int {
        var check = Check()
        let invalid: [[ModelMessage]] = [
            [.init(role: "user", content: "unanswered")],
            [.init(role: "assistant", content: "a"), .init(role: "user", content: "u")],
            [.init(role: "user", content: "u"), .init(role: "user", content: "u")],
            [.init(role: "system", content: "s"), .init(role: "assistant", content: "a")],
            [.init(role: "User", content: "u"), .init(role: "assistant", content: "a")],
            pair("u", "a") + [.init(role: "assistant", content: "extra")],
            [.init(role: "user", content: "u"), .init(role: "tool", content: "result")] + history(40)
        ]
        for input in invalid {
            try check.rejects(.invalidHistory) { _ = try ChatContextWindow(history: input, context: [], prompt: "current") }
        }
        try check.expect(invalid.last?.last?.content == "assistant-39", "Invalid omitted prefix is rejected without modifying later history")
        return check.count
    }
}

#if CHAT_CONTEXT_WINDOW_STANDALONE
@main struct ChatContextWindowCheckMain {
    static func main() throws {
        let count = try ChatContextWindowChecks.longConversation()
            + ChatContextWindowChecks.utf8AndExactCurrentTurn()
            + ChatContextWindowChecks.contiguousSuffix()
            + ChatContextWindowChecks.currentLimits()
            + ChatContextWindowChecks.malformedHistory()
        print("PASS ChatContextWindow: \(count) assertions across 5 groups; actual pure implementation, no HTTP or App execution")
    }
}
#else
final class ChatContextWindowTests: XCTestCase {
    func testLongConversationRetainsCompleteRecentTurnsAndOriginalHistory() throws {
        XCTAssertGreaterThan(try ChatContextWindowChecks.longConversation(), 0)
    }
    func testUTF8BudgetPreservesExactCurrentContextAndPrompt() throws {
        XCTAssertGreaterThan(try ChatContextWindowChecks.utf8AndExactCurrentTurn(), 0)
    }
    func testOversizedPairStopsSelectionWithoutSkippingToOlderTurns() throws {
        XCTAssertGreaterThan(try ChatContextWindowChecks.contiguousSuffix(), 0)
    }
    func testCurrentTurnBoundsRejectWithoutTruncation() throws {
        XCTAssertGreaterThan(try ChatContextWindowChecks.currentLimits(), 0)
    }
    func testMalformedHistoryIsRejectedEvenWhenItWouldBeOmitted() throws {
        XCTAssertGreaterThan(try ChatContextWindowChecks.malformedHistory(), 0)
    }
}
#endif
