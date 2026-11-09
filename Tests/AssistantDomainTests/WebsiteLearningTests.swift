import Foundation
#if !WEBSITE_LEARNING_HARNESS
import XCTest
import AssistantBrowser
#endif

// This exact fixture suite can also run with swiftc -D WEBSITE_LEARNING_HARNESS
// plus BrowserContracts, BrowserPolicy, WebsiteKnowledge*.swift and WebRoute*.swift.
// No network, user data, credentials, persistence or UI frameworks are involved.
private struct WebsiteFixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private final class WebsiteLearningChecks {
    var assertions = 0
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    let originURL = URL(string: "https://example.com")!

    func expect(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        assertions += 1
        guard try value() else { throw WebsiteFixtureFailure(description: name) }
    }
    func rejects(_ name: String, error expected: WebsiteLearningError? = nil, _ action: () throws -> Void) throws {
        assertions += 1
        do { try action() }
        catch {
            if let expected = expected, (error as? WebsiteLearningError) != expected {
                throw WebsiteFixtureFailure(description: "Wrong rejection: " + name)
            }
            return
        }
        throw WebsiteFixtureFailure(description: "Did not reject: " + name)
    }
    func page(_ path: String = "/guide", text: String = "繁體中文指南：文件在指南頁。 Public guide and reference.",
              offset: Double = 0, origin: String = "https://example.com") -> PageSnapshot {
        PageSnapshot(url: URL(string: origin + path)!, title: "Public guide", visibleText: text,
                     capturedAt: epoch.addingTimeInterval(offset))
    }
    func evidence(_ offset: Double = 0) throws -> WebsiteLessonEvidence {
        try WebsiteLessonEvidence(snapshot: page(offset: offset), quote: "文件在指南頁")
    }
    func task(_ offset: Double = 10, outcome: WebTaskOutcome = .succeeded, confirmed: Bool = true) throws -> WebTaskEvidence {
        try WebTaskEvidence(outcome: outcome, confirmed: confirmed, summary: "已核對公開指南", completedAt: epoch.addingTimeInterval(offset))
    }
    func steps(_ offset: Double = 0, secondPath: String = "/guide") throws -> [WebRouteStep] {
        [try WebRouteStep(kind: .navigate, snapshot: page(secondPath, offset: offset), evidenceQuote: "Public guide"),
         try WebRouteStep(kind: .observe, snapshot: page(secondPath, offset: offset + 1), evidenceQuote: "文件在指南頁")]
    }
    func altered<T: Encodable>(_ value: T, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func run() throws {
        try originsAndEvidence()
        try knowledgeLifecycle()
        try knowledgeBoundsAndDecoding()
        try routeLifecycle()
        try routeOriginalGoal()
        try routeBoundsAndDecoding()
    }

    func originsAndEvidence() throws {
        let canonical = try WebsiteOrigin(url: originURL)
        for raw in ["https://EXAMPLE.com:443/guide", "https://example.com./docs", "HTTPS://example.com"] {
            try expect(WebsiteOrigin(url: URL(string: raw)!) == canonical, "Origin normalization")
        }
        for raw in ["http://example.com", "https://sub.example.com", "https://example.com:8443"] {
            try expect(WebsiteOrigin(url: URL(string: raw)!) != canonical, "Exact origin separation")
        }
        for raw in ["file:///tmp/guide", "javascript:alert(1)", "https://localhost/docs", "http://127.0.0.1",
                    "http://192.168.1.2", "http://10.0.0.1", "http://[::1]", "https://user:fake@example.com",
                    "https://@example.com", "https://example.com/?token=fixture", "https://example.com/#fixture",
                    "https://example.com/?", "https://example.com/#", "https://intranet", "https://app.internal",
                    "https://example.com/webhook/fixture", "https://example.com/token/fixture",
                    "https://example.com/logout", "https://example.com/delete/item",
                    "https://example.com/%2577ebhook/fixture", "https://example.com/0123456789abcdef0123456789abcdef"] {
            try rejects("Unsafe origin URL") { _ = try WebsiteOrigin(url: URL(string: raw)!) }
        }
        try expect(WebsiteOrigin(url: URL(string: "http://example.com:80/")!).url.absoluteString == "http://example.com", "HTTP default port")
        try expect(WebsiteOrigin(url: URL(string: "https://[2606:4700:4700::1111]/docs")!).url.host != nil, "Public IPv6")
        let quoted = try evidence()
        try expect(quoted.origin == canonical, "Evidence exact origin")
        try expect(quoted.quote == "文件在指南頁", "Unicode quote retained")
        try expect(quoted.pageDigest.count == 64, "Evidence SHA256")
        try expect(try JSONDecoder().decode(WebsiteLessonEvidence.self, from: JSONEncoder().encode(quoted)) == quoted, "Evidence Codable")
        try rejects("Invented quote", error: .invalidEvidence) { _ = try WebsiteLessonEvidence(snapshot: page(), quote: "不存在的證據") }
        try rejects("Single character quote", error: .invalidEvidence) { _ = try WebsiteLessonEvidence(snapshot: page(), quote: "文") }
        try rejects("Oversized quote") { _ = try WebsiteLessonEvidence(snapshot: page(), quote: String(repeating: "a", count: 513)) }
        try rejects("Future invalid date") {
            _ = try WebsiteLessonEvidence(snapshot: PageSnapshot(url: originURL, title: "", visibleText: "guide",
                                                                 capturedAt: Date(timeIntervalSince1970: .infinity)), quote: "guide")
        }
        for secret in ["password: not-a-real-password", "api_key=fixtureValue", "Bearer fixture-not-real", "驗證碼：123456",
                       "-----BEGIN PRIVATE KEY-----", "https://example.com/webhook/not-real", "Cookie: fixture=value",
                       "ghp_abcdefghijklmnop1234567890", "sk-abcdefghijklmnop1234567890", "otp: 123456"] {
            try rejects("Sensitive evidence", error: .sensitiveContent) {
                _ = try WebsiteLessonEvidence(snapshot: page(text: secret), quote: secret)
            }
        }
        let original = page(text: "cafe\u{301} guide")
        try expect(WebsiteLessonEvidence(snapshot: original, quote: "café").quote == "café", "Canonical Unicode grounding")
        let forgedHash = try altered(quoted) { $0["pageDigest"] = "not-a-digest" }
        try rejects("Malformed evidence hash") { _ = try JSONDecoder().decode(WebsiteLessonEvidence.self, from: forgedHash) }
        let forgedURL = try altered(quoted) { $0["sourceURL"] = "http://127.0.0.1/private" }
        try rejects("Unsafe decoded evidence URL") { _ = try JSONDecoder().decode(WebsiteLessonEvidence.self, from: forgedURL) }
    }

    func knowledgeLifecycle() throws {
        var state = WebsiteKnowledgeState()
        let initial = state
        let proof = try evidence(), success = try task()
        let first = try state.addManual(text: "文件在指南頁", evidence: proof, now: epoch.addingTimeInterval(20))
        try expect(state.revision != initial.revision, "Knowledge generation changes")
        try expect(state.lessons.first?.source == .manual && state.lessons.first?.status == .approved, "Manual approval honest source")
        try expect(state.context(for: originURL).count == 1, "Approved context injected")
        try expect(state.context(for: URL(string: "https://other.example.com")!).isEmpty, "No subdomain bleed")
        try expect(state.context(for: URL(string: "http://example.com")!).isEmpty, "No scheme bleed")
        try expect(state.context(for: originURL, limit: -1).isEmpty, "Negative context limit")
        let pending = try state.propose(text: "公開頁面可找到指南", evidence: proof, task: success, now: epoch.addingTimeInterval(21))
        try expect(state.lessons.last?.status == .pending, "Judged success remains pending")
        try expect(state.context(for: originURL).count == 1, "Pending not injected")
        try expect(state.search("指南", originURL: originURL).count == 2, "Management search includes pending")
        let beforeApproval = state
        try state.approve(id: pending, now: epoch.addingTimeInterval(22))
        try expect(state.context(for: originURL).count == 2, "Explicit approval enables context")
        try expect(state.revisions.count == 1 && state.revisions[0].lesson.status == .pending, "Approval revision preserved")
        try expect(state.contentHash != beforeApproval.contentHash, "Content hash changes")
        let approved = state
        try state.approve(id: pending, now: epoch.addingTimeInterval(23))
        try expect(state == approved, "Duplicate approval no-op")
        try state.edit(id: first, text: "更新：文件在指南頁", evidence: proof, now: epoch.addingTimeInterval(24))
        try expect(state.revisions.last?.lesson.text == "文件在指南頁", "Edit archives previous content")
        let editRevision = state.revisions.last!.id, preRestore = state
        try rejects("Stale restore", error: .staleRevision) {
            _ = try state.restore(revisionID: editRevision, expectedCurrentHash: initial.contentHash, now: epoch.addingTimeInterval(25))
        }
        try expect(state == preRestore, "Failed restore atomic")
        let restored = try state.restore(revisionID: editRevision, expectedCurrentHash: state.contentHash, now: epoch.addingTimeInterval(26))
        try expect(restored == first && state.lessons.first?.text == "文件在指南頁", "Hash guarded restore")
        try state.delete(id: first, now: epoch.addingTimeInterval(27))
        try expect(state.lessons.count == 1 && state.revisions.last?.reason == .delete, "Recoverable delete")
        let deletion = state.revisions.last!.id
        _ = try state.restore(revisionID: deletion, expectedCurrentHash: state.contentHash, now: epoch.addingTimeInterval(28))
        try expect(state.lessons.contains(where: { $0.id == first }), "Deleted item restored with same ID")
        _ = try state.restore(revisionID: state.revisions[0].id, expectedCurrentHash: state.contentHash, now: epoch.addingTimeInterval(29))
        try expect(state.lessons.first(where: { $0.id == pending })?.status == .pending, "Restoring pending never promotes")
        let saved = state
        try rejects("Cross origin edit", error: .originMismatch) {
            let other = try WebsiteLessonEvidence(snapshot: page(origin: "https://other.example.com"), quote: "文件在指南頁")
            try state.edit(id: first, text: "wrong site", evidence: other)
        }
        try expect(state == saved, "Cross origin rejection atomic")
        try rejects("Missing delete", error: .notFound) { try state.delete(id: UUID()) }
        try rejects("Clock reversal", error: .invalidState) { try state.delete(id: first, now: epoch) }
        try expect(state == saved, "Clock reversal rejection atomic")
        let roundTrip = try JSONDecoder().decode(WebsiteKnowledgeState.self, from: JSONEncoder().encode(state))
        try expect(roundTrip == state && roundTrip.contentHash == state.contentHash, "Knowledge Codable/hash roundtrip")
        state.clear()
        try expect(state.lessons.isEmpty && state.revisions.isEmpty && state.revision != saved.revision, "Clear removes history and changes generation")
        try rejects("Clear cannot resurrect", error: .notFound) {
            _ = try state.restore(revisionID: deletion, expectedCurrentHash: state.contentHash)
        }
    }

    func knowledgeBoundsAndDecoding() throws {
        let proof = try evidence()
        var state = WebsiteKnowledgeState()
        for outcome in [WebTaskOutcome.partial, .failed, .cancelled, .unknown] {
            let result = try task(outcome: outcome)
            try rejects("Unsuccessful task cannot propose", error: .ineligibleTask) {
                _ = try state.propose(text: "guide", evidence: proof, task: result)
            }
        }
        let unconfirmed = try task(confirmed: false)
        try rejects("Unconfirmed task cannot propose", error: .ineligibleTask) {
            _ = try state.propose(text: "guide", evidence: proof, task: unconfirmed)
        }
        for invalid in ["", String(repeating: "a", count: 1501), "password: fixtureOnly", "private\u{202E}value"] {
            try rejects("Invalid lesson") { _ = try state.addManual(text: invalid, evidence: proof) }
        }
        try expect(state.lessons.isEmpty, "Failed additions leave empty store")
        for index in 0..<WebsiteKnowledgeState.maximumLessons {
            _ = try state.addManual(text: "Guide \(index)", evidence: proof)
        }
        let full = state
        try rejects("Lesson cap", error: .capacityExceeded) { _ = try state.addManual(text: "overflow", evidence: proof) }
        try expect(state == full, "Capacity rejection atomic")
        try expect(state.context(for: originURL, limit: Int.max).count == 10, "Context bounded")
        let duplicate = try altered(state) { object in
            var rows = object["lessons"] as! [[String: Any]]; rows[1] = rows[0]; object["lessons"] = rows
        }
        try rejects("Decoded duplicate lesson ID") { _ = try JSONDecoder().decode(WebsiteKnowledgeState.self, from: duplicate) }
        let poisoned = try altered(state) { object in
            var rows = object["lessons"] as! [[String: Any]]; rows[0]["text"] = "api_key=fixtureOnly"; object["lessons"] = rows
        }
        try rejects("Decoded sensitive lesson") { _ = try JSONDecoder().decode(WebsiteKnowledgeState.self, from: poisoned) }
        var journal = WebsiteKnowledgeState()
        let id = try journal.addManual(text: "guide", evidence: proof)
        for index in 0..<105 { try journal.edit(id: id, text: "Revision \(index)", evidence: proof) }
        try expect(journal.revisions.count == WebsiteKnowledgeState.maximumRevisions, "Revision ring bounded")
        try expect(journal.revisions.first?.lesson.text == "Revision 4", "Oldest revisions pruned deterministically")
        let poisonedHistory = try altered(journal) { object in
            var rows = object["revisions"] as! [[String: Any]]
            var lesson = rows[0]["lesson"] as! [String: Any]; lesson["text"] = "password: fixtureOnly"
            rows[0]["lesson"] = lesson; object["revisions"] = rows
        }
        try rejects("Decoded sensitive historical revision") { _ = try JSONDecoder().decode(WebsiteKnowledgeState.self, from: poisonedHistory) }
    }

    func routeLifecycle() throws {
        var state = WebRouteState()
        let observed = try steps(), result = try task()
        let id = try state.record(intent: "  Read   Guide  ", steps: observed, task: result)
        let route = state.routes[0]
        try expect(route.intent == "read guide" && route.successes == 1, "Confirmed initial route success")
        try expect(state.match(originURL: originURL, intent: "READ\n GUIDE").count == 1, "Exact normalized intent match")
        try expect(state.match(originURL: originURL, intent: "read different guide").isEmpty, "No inferred route intent")
        try expect(state.match(originURL: URL(string: "https://sub.example.com")!, intent: "read guide").isEmpty, "No cross origin route match")
        let plan = try state.replayPlan(id: id, originURL: originURL, intent: "read guide", expectedContentHash: route.contentHash)
        try expect(plan.steps == observed && plan.routeID == id, "Plan uses only recorded observations")
        try expect(plan.requiresUserConfirmation && plan.requiresPolicyValidationPerStep, "Plan never grants approval")
        try expect(state.routes[0].successes == 1, "Plan creation not execution success")
        try rejects("Plan stale hash", error: .staleRevision) {
            _ = try state.replayPlan(id: id, originURL: originURL, intent: "read guide", expectedContentHash: "stale")
        }
        try rejects("Plan wrong intent", error: .intentMismatch) {
            _ = try state.replayPlan(id: id, originURL: originURL, intent: "different", expectedContentHash: route.contentHash)
        }
        try rejects("Plan wrong origin", error: .originMismatch) {
            _ = try state.replayPlan(id: id, originURL: URL(string: "http://example.com")!, intent: "read guide", expectedContentHash: route.contentHash)
        }
        let unchanged = state
        try state.recordReplayResult(id: id, expectedContentHash: route.contentHash, result: .cancelled)
        try expect(state == unchanged, "Cancelled replay neutral")
        try state.recordReplayResult(id: id, expectedContentHash: route.contentHash, result: .awaitingApproval)
        try expect(state == unchanged, "Waiting approval neutral")
        try rejects("Old observations are not fresh replay evidence", error: .invalidEvidence) {
            try state.recordReplayResult(id: id, expectedContentHash: route.contentHash,
                                         result: .succeeded(observedSteps: observed, task: task(30)))
        }
        let fresh = try steps(20)
        try rejects("Incomplete replay cannot count", error: .ineligibleTask) {
            try state.recordReplayResult(id: id, expectedContentHash: route.contentHash,
                                         result: .succeeded(observedSteps: Array(fresh.prefix(1)), task: task(30)))
        }
        let changedQuote = [fresh[0], try WebRouteStep(kind: .observe, snapshot: page(offset: 21), evidenceQuote: "Public guide")]
        try rejects("Changed observation anchor cannot count", error: .invalidEvidence) {
            try state.recordReplayResult(id: id, expectedContentHash: route.contentHash,
                                         result: .succeeded(observedSteps: changedQuote, task: task(30)))
        }
        try expect(state == unchanged, "Rejected result atomic")
        try state.recordReplayResult(id: id, expectedContentHash: route.contentHash,
                                     result: .succeeded(observedSteps: fresh, task: task(30)))
        try expect(state.routes[0].successes == 2 && state.routes[0].contentHash != route.contentHash, "Fresh verified replay increments once")
        try rejects("Duplicate result rejected as stale", error: .staleRevision) {
            try state.recordReplayResult(id: id, expectedContentHash: route.contentHash,
                                         result: .succeeded(observedSteps: fresh, task: task(30)))
        }
        let coincident = try steps(30)
        try rejects("Fresh hash cannot reuse observations at previous completion time", error: .invalidEvidence) {
            try state.recordReplayResult(id: id, expectedContentHash: state.routes[0].contentHash,
                                         result: .succeeded(observedSteps: coincident, task: task(32)))
        }
        try state.recordReplayResult(id: id, expectedContentHash: state.routes[0].contentHash,
                                     result: .diverged(stepIndex: 1, at: epoch.addingTimeInterval(31)))
        try expect(state.routes[0].consecutiveMisses == 1 && !state.routes[0].disabled, "First mismatch retained")
        try state.recordReplayResult(id: id, expectedContentHash: state.routes[0].contentHash,
                                     result: .diverged(stepIndex: 0, at: epoch.addingTimeInterval(32)))
        try expect(state.routes[0].consecutiveMisses == 1 && state.routes[0].missStep == 0, "Different failed step resets streak")
        try state.recordReplayResult(id: id, expectedContentHash: state.routes[0].contentHash,
                                     result: .diverged(stepIndex: 0, at: epoch.addingTimeInterval(33)))
        try expect(state.routes[0].disabled && state.routes[0].consecutiveMisses == 2, "Two same step misses disable")
        try expect(state.match(originURL: originURL, intent: "read guide").isEmpty, "Disabled route not matched")
        try rejects("Disabled plan blocked", error: .disabledRoute) {
            _ = try state.replayPlan(id: id, originURL: originURL, intent: "read guide", expectedContentHash: state.routes[0].contentHash)
        }
        let same = try state.record(intent: "read guide", steps: steps(40), task: task(50))
        try expect(same == id && state.routes.count == 1, "Same intent replaces not duplicates")
        try expect(state.routes[0].disabled && state.routes[0].successes == 2, "Same path rerecord preserves disabled and successes")
        _ = try state.record(intent: "read guide", steps: steps(60, secondPath: "/reference"), task: task(70))
        try expect(!state.routes[0].disabled && state.routes[0].consecutiveMisses == 0, "Different demonstrated path resets misses")
        let roundTrip = try JSONDecoder().decode(WebRouteState.self, from: JSONEncoder().encode(state))
        try expect(roundTrip == state && roundTrip.routes[0].contentHash == state.routes[0].contentHash, "Route Codable/hash roundtrip")
        let beforeDelete = state.revision
        try state.delete(id: id)
        try expect(state.routes.isEmpty && state.revision != beforeDelete, "Delete changes route generation")
        try rejects("Deleted route absent", error: .notFound) { try state.delete(id: id) }
        _ = try state.record(intent: "read guide", steps: observed, task: result)
        let beforeClear = state.revision; state.clear()
        try expect(state.routes.isEmpty && state.revision != beforeClear, "Clear removes routes")
    }

    func routeOriginalGoal() throws {
        var state = WebRouteState()
        let goal = "  Reply EXACTLY \"WOOW_TAG\"\nThen preserve \"A  B\tC\".\r\nLiteral cafe\u{301}.  "
        let key = "reply exactly \"woow_tag\" then preserve \"a b c\". literal café."
        let id = try state.record(intent: goal, steps: steps(), task: task())
        let saved = state.routes[0]
        try expect(Array(saved.originalGoal.utf8) == Array(goal.utf8), "Original goal preserves exact bytes, case, whitespace and Unicode")
        try expect(saved.originalGoal.contains("WOOW_TAG"), "Uppercase exact output marker retained")
        try expect(saved.originalGoal.contains("A  B\tC"), "Quoted whitespace literal retained")
        try expect(saved.intent == key, "Only matching key is normalized")
        try expect(state.match(originURL: originURL, intent: key).first?.id == id, "Normalized key still matches")
        let plan = try state.replayPlan(id: id, originURL: originURL, intent: goal, expectedContentHash: saved.contentHash)
        try expect(plan.routeID == id && plan.requiresUserConfirmation, "Original goal accepted by guarded replay matching")

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WebRouteState.self, from: encoded)
        try expect(Array(decoded.routes[0].originalGoal.utf8) == Array(goal.utf8), "Original goal Codable exact-byte roundtrip")
        try expect(decoded == state && decoded.routes[0].contentHash == saved.contentHash, "Original goal hash stable on roundtrip")
        let changedCaseOnly = try altered(saved) { $0["originalGoal"] = goal.replacingOccurrences(of: "WOOW_TAG", with: "woow_tag") }
        let changed = try JSONDecoder().decode(WebRoute.self, from: changedCaseOnly)
        try expect(changed.intent == saved.intent && changed.contentHash != saved.contentHash, "Hash covers case-sensitive original independently of match key")
        let changedSpacesOnly = try altered(saved) { $0["originalGoal"] = goal.replacingOccurrences(of: "A  B", with: "A B") }
        try expect(JSONDecoder().decode(WebRoute.self, from: changedSpacesOnly).contentHash != saved.contentHash, "Hash covers exact literal whitespace")

        let legacyData = try altered(saved) { $0.removeValue(forKey: "originalGoal") }
        let legacy = try JSONDecoder().decode(WebRoute.self, from: legacyData)
        try expect(legacy.originalGoal == saved.intent && legacy.intent == saved.intent, "Legacy missing original falls back to intent")
        let legacyRoundTrip = try JSONDecoder().decode(WebRoute.self, from: JSONEncoder().encode(legacy))
        try expect(legacyRoundTrip == legacy && legacyRoundTrip.contentHash == legacy.contentHash, "Legacy migration roundtrip")
        let legacyState = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]
            routes[0].removeValue(forKey: "originalGoal"); object["routes"] = routes
        }
        try expect(JSONDecoder().decode(WebRouteState.self, from: legacyState).routes[0].originalGoal == key, "Legacy nested state decodes")
        for badGoal in ["a different request", "password: fixtureOnly", String(repeating: "a", count: 4001), "   "] {
            let poisoned = try altered(saved) { $0["originalGoal"] = badGoal }
            try rejects("Decoded original must be safe, bounded and match intent") { _ = try JSONDecoder().decode(WebRoute.self, from: poisoned) }
        }
        let nullGoal = try altered(saved) { $0["originalGoal"] = NSNull() }
        try rejects("Explicit null is malformed, not legacy omission") { _ = try JSONDecoder().decode(WebRoute.self, from: nullGoal) }

        let revisedGoal = "REPLY exactly \"woow_TAG\"\tThen preserve \"A B C\".\nLiteral café."
        let replacementID = try state.record(intent: revisedGoal, steps: steps(20), task: task(30))
        try expect(replacementID == id && state.routes.count == 1, "Same normalized intent deduplicates")
        try expect(Array(state.routes[0].originalGoal.utf8) == Array(revisedGoal.utf8), "Rerecord keeps latest original, not old goal or normalized copy")
        try expect(state.routes[0].intent == key && state.routes[0].successes == saved.successes, "Rerecord preserves matching key and success statistics")
        try rejects("Previous goal hash cannot replay latest goal", error: .staleRevision) {
            _ = try state.replayPlan(id: id, originURL: originURL, intent: revisedGoal, expectedContentHash: saved.contentHash)
        }

        var bounded = WebRouteState()
        let maximumGoal = String(repeating: "A", count: 4000)
        _ = try bounded.record(intent: maximumGoal, steps: steps(), task: task())
        try expect(bounded.routes[0].originalGoal == maximumGoal && bounded.routes[0].intent.count == 4000, "4000 UTF16 goal and match key accepted")
        try expect(bounded.match(originURL: originURL, intent: maximumGoal.lowercased()).count == 1, "Long normalized matching supported")
        let beforeFailure = bounded
        for invalid in [String(repeating: "a", count: 4001), String(repeating: " ", count: 4000) + "a",
                        "\n\t  \r\n", "Reply with api_key=fixtureOnly", "Literal\u{0000}value", "Literal\u{202E}value"] {
            try rejects("Invalid original goal rejected") { _ = try bounded.record(intent: invalid, steps: steps(), task: task()) }
        }
        try expect(bounded == beforeFailure, "Invalid original goal changes are atomic")
        var unicode = WebRouteState()
        let expandedKeyGoal = String(repeating: "İ", count: 4000)
        _ = try unicode.record(intent: expandedKeyGoal, steps: steps(), task: task())
        let unicodeDecoded = try JSONDecoder().decode(WebRouteState.self, from: JSONEncoder().encode(unicode))
        try expect(unicodeDecoded == unicode, "Unicode lowercase expansion does not break decoding")
        try expect(unicode.match(originURL: originURL, intent: expandedKeyGoal).count == 1, "Unicode long original matches")
    }

    func routeBoundsAndDecoding() throws {
        var state = WebRouteState()
        let observed = try steps(), result = try task()
        for outcome in [WebTaskOutcome.partial, .failed, .cancelled, .unknown] {
            try rejects("Unsuccessful route rejected", error: .ineligibleTask) {
                _ = try state.record(intent: "read guide", steps: observed, task: task(outcome: outcome))
            }
        }
        try rejects("Unconfirmed route rejected", error: .ineligibleTask) {
            _ = try state.record(intent: "read guide", steps: observed, task: task(confirmed: false))
        }
        try rejects("No observations rejected", error: .invalidEvidence) { _ = try state.record(intent: "read guide", steps: [], task: result) }
        let other = try WebRouteStep(kind: .observe, snapshot: page(offset: 2, origin: "https://other.example.com"), evidenceQuote: "Public guide")
        try rejects("Cross origin recorded route", error: .originMismatch) {
            _ = try state.record(intent: "read guide", steps: observed + [other], task: result)
        }
        let changedPage = try WebRouteStep(kind: .observe, snapshot: page("/different", offset: 2), evidenceQuote: "Public guide")
        try rejects("An observation cannot infer missing navigation", error: .invalidEvidence) {
            _ = try state.record(intent: "read guide", steps: observed + [changedPage], task: result)
        }
        let navigatedPage = try WebRouteStep(kind: .navigate, snapshot: page("/different", offset: 2), evidenceQuote: "Public guide")
        var multiPage = WebRouteState()
        _ = try multiPage.record(intent: "read multiple pages", steps: observed + [navigatedPage], task: result)
        try expect(multiPage.routes[0].steps.count == 3, "Explicit actual navigation retained")
        let initialRead = try WebRouteStep(kind: .observe, snapshot: page(), evidenceQuote: "Public guide")
        var initialState = WebRouteState()
        _ = try initialState.record(intent: "read current page", steps: [initialRead], task: result)
        try expect(initialState.routes[0].steps[0].kind == .observe, "Initial inspection records no invented navigation")
        try rejects("Nonmonotonic observations", error: .invalidState) {
            _ = try state.record(intent: "read guide", steps: observed.reversed(), task: result)
        }
        try rejects("Outcome before observation", error: .invalidState) {
            _ = try state.record(intent: "read guide", steps: observed, task: task(-1))
        }
        try rejects("Route step bound", error: .invalidEvidence) {
            _ = try state.record(intent: "read guide", steps: Array(repeating: observed[0], count: 61), task: result)
        }
        try rejects("Secret in intent", error: .sensitiveContent) {
            _ = try state.record(intent: "password: fixtureOnly", steps: observed, task: result)
        }
        try rejects("Oversized intent", error: .invalidText) {
            _ = try state.record(intent: String(repeating: "a", count: 4001), steps: observed, task: result)
        }
        try expect(state.routes.isEmpty, "Rejected routes leave state untouched")
        let id = try state.record(intent: "read guide", steps: observed, task: result)
        let good = state
        try rejects("Invalid failed step", error: .invalidEvidence) {
            try state.recordReplayResult(id: id, expectedContentHash: state.routes[0].contentHash,
                                         result: .diverged(stepIndex: 2, at: epoch.addingTimeInterval(20)))
        }
        try expect(state == good, "Invalid mismatch atomic")
        let script = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]
            var steps = routes[0]["steps"] as! [[String: Any]]; steps[0]["kind"] = "evaluateJavaScript"
            routes[0]["steps"] = steps; object["routes"] = routes
        }
        try rejects("Decoded script step rejected") { _ = try JSONDecoder().decode(WebRouteState.self, from: script) }
        let mismatchOrigin = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]; routes[0]["origin"] = "https://other.example.com"; object["routes"] = routes
        }
        try rejects("Decoded route scope mismatch") { _ = try JSONDecoder().decode(WebRouteState.self, from: mismatchOrigin) }
        let overflow = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]; routes[0]["successes"] = -1; object["routes"] = routes
        }
        try rejects("Decoded invalid statistics") { _ = try JSONDecoder().decode(WebRouteState.self, from: overflow) }
        let duplicate = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]; routes.append(routes[0]); object["routes"] = routes
        }
        try rejects("Decoded duplicate routes") { _ = try JSONDecoder().decode(WebRouteState.self, from: duplicate) }
        let poisoned = try altered(state) { object in
            var routes = object["routes"] as! [[String: Any]]
            var task = routes[0]["task"] as! [String: Any]; task["confirmed"] = false
            routes[0]["task"] = task; object["routes"] = routes
        }
        try rejects("Decoded unconfirmed result") { _ = try JSONDecoder().decode(WebRouteState.self, from: poisoned) }
        for index in 1..<WebRouteState.maximumRoutes { _ = try state.record(intent: "read guide \(index)", steps: observed, task: result) }
        let full = state
        try rejects("Route count cap", error: .capacityExceeded) { _ = try state.record(intent: "overflow", steps: observed, task: result) }
        try expect(state == full, "Route cap rejection atomic")
    }
}

#if WEBSITE_LEARNING_HARNESS
@main
private struct WebsiteLearningHarness {
    static func main() throws {
        let checks = WebsiteLearningChecks(); try checks.run()
        print("Website learning: \(checks.assertions) offline assertions passed")
    }
}
#else
final class WebsiteLearningTests: XCTestCase {
    func testNativeWebsiteKnowledgeAndReadOnlyRoutes() throws {
        let checks = WebsiteLearningChecks(); try checks.run()
        XCTAssertGreaterThan(checks.assertions, 100)
    }
}
#endif
