import Foundation
import AssistantBrowser

enum BrowserInteractionFixtures {
    struct Failure: Error { let message: String }
    static func run() throws -> Int {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw Failure(message: message) }
        }
        func refused(_ expected: BrowserInteractionError, _ operation: () throws -> Void) throws {
            assertions += 1
            do { try operation(); throw Failure(message: "Expected refusal: \(expected)") }
            catch let error as BrowserInteractionError {
                if error != expected { throw Failure(message: "Wrong refusal: \(error) instead of \(expected)") }
            }
        }
        let url = URL(string: "https://example.com/form")!
        let controls: [BrowserDOMControl] = [
            .init(id: "text", kind: .text, label: "Note"),
            .init(id: "button", kind: .button, label: "Submit", navigationURL: url, navigationMethod: "POST"),
            .init(id: "select", kind: .select, label: "Mode", options: [.init(index: 0, label: "First"), .init(index: 1, label: "Disabled", disabled: true)]),
            .init(id: "disabled", kind: .button, label: "Disabled", enabled: false),
            .init(id: "internal", kind: .link, label: "Internal", navigationURL: URL(string: "https://127.0.0.1/")),
            .init(id: "toggle", kind: .toggle, label: "Opt in")
        ]
        let snapshot = BrowserDOMSnapshot(documentID: "document", snapshotID: "snapshot", url: url, controls: controls)
        func request(_ kind: BrowserInteractionKind, _ id: String? = nil, text: String? = nil, option: Int? = nil,
                     direction: BrowserScrollDirection? = nil) -> BrowserInteractionRequest {
            .init(documentID: "document", snapshotID: "snapshot", kind: kind, controlID: id,
                  text: text, optionIndex: option, direction: direction)
        }
        let accepted: [BrowserInteractionRequest] = [request(.click, "button"), request(.click, "toggle"),
            request(.type, "text", text: "Hello\n世界\t'\";alert(1)"), request(.type, "text", text: ""),
            request(.type, "text", text: String(repeating: "a", count: 4096)), request(.select, "select", option: 0),
            request(.scroll, direction: .up), request(.scroll, direction: .down)]
        let now = Date(timeIntervalSince1970: 10)
        for value in accepted {
            var gate = BrowserInteractionGate()
            let proposal = try gate.propose(value, snapshot: snapshot, now: now)
            try expect(gate.pending?.id == proposal.id, "Every action waits for approval")
            try expect(proposal.request == value, "Approval binds exact arguments")
            let consumed = try gate.consumeApproval(id: proposal.id, now: now)
            try expect(consumed == proposal && gate.pending == nil, "Single consumption")
            try refused(.approvalRequired) { _ = try gate.consumeApproval(id: proposal.id, now: now) }
        }
        let invalid: [(BrowserInteractionRequest, BrowserInteractionError)] = [
            (request(.click, "missing"), .unavailableControl), (request(.click, "disabled"), .unavailableControl),
            (request(.click, "internal"), .unsafeDestination), (request(.click, "text"), .invalidRequest),
            (request(.click, "button", text: "extra"), .invalidRequest), (request(.type, "button", text: "x"), .invalidRequest),
            (request(.type, "text"), .invalidRequest), (request(.type, "text", text: "\u{00}"), .invalidRequest),
            (request(.type, "text", text: String(repeating: "界", count: 1400)), .invalidRequest),
            (request(.select, "select", option: 1), .invalidRequest), (request(.select, "select", option: -1), .invalidRequest),
            (request(.select, "select", option: 99), .invalidRequest), (request(.select, "select", text: "extra", option: 0), .invalidRequest),
            (request(.scroll), .invalidRequest), (request(.scroll, "text", direction: .down), .invalidRequest),
            (request(.scroll, text: "extra", direction: .down), .invalidRequest),
            (.init(documentID: "old", snapshotID: "snapshot", kind: .click, controlID: "button"), .staleSnapshot),
            (.init(documentID: "document", snapshotID: "old", kind: .click, controlID: "button"), .staleSnapshot)
        ]
        for (value, reason) in invalid {
            try refused(reason) { try BrowserInteractionGate.validate(value, snapshot: snapshot) }
        }
        var gate = BrowserInteractionGate()
        let first = try gate.propose(accepted[0], snapshot: snapshot, now: now)
        gate.reject()
        try refused(.approvalRequired) { _ = try gate.consumeApproval(id: first.id, now: now) }
        let expired = try gate.propose(accepted[0], snapshot: snapshot, now: now)
        try refused(.expiredApproval) { _ = try gate.consumeApproval(id: expired.id, now: now.addingTimeInterval(60)) }
        try expect(gate.pending == nil, "Expired grant is discarded")
        let replaced = try gate.propose(accepted[0], snapshot: snapshot, now: now)
        let replacement = try gate.propose(accepted[1], snapshot: snapshot, now: now)
        try refused(.approvalRequired) { _ = try gate.consumeApproval(id: replaced.id, now: now) }
        try expect(gate.pending?.id == replacement.id, "Wrong approval cannot consume the new proposal")
        try refused(.invalidRequest) { _ = try gate.propose(request(.scroll), snapshot: snapshot, now: now) }
        try expect(gate.pending == nil, "Invalid replacement clears earlier authorization")
        for badURL in ["http://example.com", "https://user:pass@example.com", "https://[::1]/"] {
            let unsafe = BrowserDOMSnapshot(documentID: "document", snapshotID: "snapshot", url: URL(string: badURL)!, controls: [])
            try refused(.unsafeDestination) { try BrowserInteractionGate.validate(request(.scroll, direction: .down), snapshot: unsafe) }
        }
        for badControls in [controls + [controls[0]], Array(repeating: controls[0], count: 201)] {
            let invalidSnapshot = BrowserDOMSnapshot(documentID: "document", snapshotID: "snapshot", url: url, controls: badControls)
            try refused(.invalidRequest) { try BrowserInteractionGate.validate(request(.scroll, direction: .down), snapshot: invalidSnapshot) }
        }
        let encoded = try JSONEncoder().encode(snapshot)
        let roundtrip = try JSONDecoder().decode(BrowserDOMSnapshot.self, from: encoded)
        try expect(snapshot == roundtrip, "Snapshot Codable")
        for value in accepted {
            let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let parsed = try BrowserInteractionPlanner.parse(json, snapshot: snapshot)
            try expect(parsed == value, "Strict planner roundtrip")
        }
        for json in ["{}", "[]", "null", "```json\n{}\n```", String(repeating: "a", count: 16_385),
            #"{"documentID":"document","snapshotID":"snapshot","kind":"eval","script":"alert(1)"}"#,
            #"{"documentID":"document","snapshotID":"snapshot","kind":"click","controlID":"button","approved":true}"#,
            #"{"documentID":"document","snapshotID":"snapshot","kind":"click","controlID":"button","text":null}"#,
            #"{"documentID":"document","snapshotID":"snapshot","kind":"select","controlID":"select","optionIndex":true}"#] {
            try refused(.invalidModelResponse) { _ = try BrowserInteractionPlanner.parse(json, snapshot: snapshot) }
        }
        return assertions
    }
}

#if BROWSER_INTERACTION_SMOKE
@main enum BrowserInteractionSmoke {
    static func main() throws { print("Browser interaction policy: \(try BrowserInteractionFixtures.run()) assertions passed") }
}
#elseif canImport(XCTest)
import XCTest
final class BrowserInteractionTests: XCTestCase {
    func testApprovalValidationAndStrictModelBoundary() throws { XCTAssertGreaterThan(try BrowserInteractionFixtures.run(), 70) }
}
#endif
