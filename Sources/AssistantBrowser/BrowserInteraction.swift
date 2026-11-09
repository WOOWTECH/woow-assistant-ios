import Foundation

// Contract informed by Mika's Interact.kt + PageTree.kt (snapshot/ref expiry and
// external-action gating). This implementation is independent and DOM-only;
// it does not emulate Mika's trusted native/CDP input events.
public enum BrowserControlKind: String, Codable, Sendable { case link, button, text, select, toggle }
public struct BrowserControlOption: Codable, Equatable, Sendable {
    public let index: Int
    public let label: String
    public let disabled: Bool
    public init(index: Int, label: String, disabled: Bool = false) {
        self.index = index; self.label = label; self.disabled = disabled
    }
}
public struct BrowserDOMControl: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: BrowserControlKind
    public let label: String
    public let enabled: Bool
    public let options: [BrowserControlOption]
    public let navigationURL: URL?
    public let navigationMethod: String?
    public init(id: String, kind: BrowserControlKind, label: String, enabled: Bool = true,
                options: [BrowserControlOption] = [], navigationURL: URL? = nil, navigationMethod: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.enabled = enabled
        self.options = options; self.navigationURL = navigationURL; self.navigationMethod = navigationMethod
    }
}
/// No field values, password/file inputs, hidden controls or executable page code.
/// Labels and options are untrusted page data, never permission or instructions.
public struct BrowserDOMSnapshot: Codable, Equatable, Sendable {
    public let documentID: String
    public let snapshotID: String
    public let url: URL
    public let controls: [BrowserDOMControl]
    public let truncated: Bool
    public init(documentID: String, snapshotID: String, url: URL, controls: [BrowserDOMControl], truncated: Bool = false) {
        self.documentID = documentID; self.snapshotID = snapshotID; self.url = url
        self.controls = controls; self.truncated = truncated
    }
}
public enum BrowserInteractionKind: String, Codable, Sendable, CaseIterable { case click, type, select, scroll }
public enum BrowserScrollDirection: String, Codable, Sendable { case up, down }
public struct BrowserInteractionRequest: Codable, Equatable, Sendable {
    public let documentID: String
    public let snapshotID: String
    public let kind: BrowserInteractionKind
    public let controlID: String?
    public let text: String?
    public let optionIndex: Int?
    public let direction: BrowserScrollDirection?
    public init(documentID: String, snapshotID: String, kind: BrowserInteractionKind, controlID: String? = nil,
                text: String? = nil, optionIndex: Int? = nil, direction: BrowserScrollDirection? = nil) {
        self.documentID = documentID; self.snapshotID = snapshotID; self.kind = kind; self.controlID = controlID
        self.text = text; self.optionIndex = optionIndex; self.direction = direction
    }
}
public struct BrowserInteractionProposal: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let request: BrowserInteractionRequest
    public let pageURL: URL
    public let control: BrowserDOMControl?
    public let expiresAt: Date
    // Not Codable: a model response or saved page cannot deserialize approval.
}
public enum BrowserInteractionError: String, Error, Sendable {
    case noSnapshot, staleSnapshot, unavailableControl, invalidRequest, unsafeDestination
    case approvalRequired, expiredApproval, busy, executionFailed, timedOut, invalidModelResponse
    public var message: String {
        switch self {
        case .noSnapshot: return "請先讀取這個網頁的控制項。"
        case .staleSnapshot: return "頁面或控制項已變更；沒有執行，請重新讀取並核准。"
        case .unavailableControl: return "這個控制項不可操作或屬於受保護欄位。"
        case .invalidRequest, .invalidModelResponse: return "動作格式無法辨識；沒有執行。"
        case .unsafeDestination: return "動作目的地不在允許的公開 HTTPS 範圍。"
        case .approvalRequired: return "這個動作尚未取得單次核准，或核准已用過。"
        case .expiredApproval: return "核准要求已逾時；請重新讀取並提出動作。"
        case .busy: return "請先停止目前的研究或網頁操作。"
        case .executionFailed: return "網頁動作未確認完成；不會自動重試。"
        case .timedOut: return "網頁回應逾時；動作可能已送出，請先確認頁面，不會重試。"
        }
    }
}
/// Owned by native orchestration, never shared with the model. Every kind,
/// including typing/select/scroll (which can trigger site listeners), requires
/// one explicit native approval. Consumption precedes execution; no retry.
public struct BrowserInteractionGate: Sendable {
    public private(set) var pending: BrowserInteractionProposal?
    public init() {}
    @discardableResult
    public mutating func propose(_ request: BrowserInteractionRequest, snapshot: BrowserDOMSnapshot,
                                 now: Date = Date()) throws -> BrowserInteractionProposal {
        pending = nil
        try Self.validate(request, snapshot: snapshot)
        let proposal = BrowserInteractionProposal(id: UUID(), request: request, pageURL: snapshot.url,
            control: snapshot.controls.first { $0.id == request.controlID }, expiresAt: now.addingTimeInterval(60))
        pending = proposal
        return proposal
    }
    public mutating func reject() { pending = nil }
    public mutating func consumeApproval(id: UUID, now: Date = Date()) throws -> BrowserInteractionProposal {
        guard let value = pending, value.id == id else { throw BrowserInteractionError.approvalRequired }
        pending = nil
        guard now < value.expiresAt else { throw BrowserInteractionError.expiredApproval }
        return value
    }
    public static func validate(_ request: BrowserInteractionRequest, snapshot: BrowserDOMSnapshot) throws {
        guard request.documentID == snapshot.documentID, request.snapshotID == snapshot.snapshotID else {
            throw BrowserInteractionError.staleSnapshot
        }
        guard !snapshot.documentID.isEmpty, snapshot.documentID.utf8.count <= 80,
              !snapshot.snapshotID.isEmpty, snapshot.snapshotID.utf8.count <= 80,
              snapshot.controls.count <= 200, Set(snapshot.controls.map(\.id)).count == snapshot.controls.count,
              snapshot.controls.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 80 && $0.label.utf8.count <= 1000 &&
                  $0.options.count <= 100 && Set($0.options.map(\.index)).count == $0.options.count &&
                  $0.options.allSatisfy({ $0.index >= 0 && $0.label.utf8.count <= 1000 }) }) else {
            throw BrowserInteractionError.invalidRequest
        }
        guard allowed(snapshot.url) else { throw BrowserInteractionError.unsafeDestination }
        if request.kind == .scroll {
            guard request.controlID == nil, request.text == nil, request.optionIndex == nil, request.direction != nil else {
                throw BrowserInteractionError.invalidRequest
            }
            return
        }
        guard let id = request.controlID, let control = snapshot.controls.first(where: { $0.id == id }), control.enabled else {
            throw BrowserInteractionError.unavailableControl
        }
        if let url = control.navigationURL, !allowed(url) { throw BrowserInteractionError.unsafeDestination }
        guard request.direction == nil else { throw BrowserInteractionError.invalidRequest }
        switch request.kind {
        case .click:
            guard [.link, .button, .toggle].contains(control.kind), request.text == nil, request.optionIndex == nil else {
                throw BrowserInteractionError.invalidRequest
            }
        case .type:
            guard control.kind == .text, let text = request.text, text.utf8.count <= 4096,
                  !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }),
                  request.optionIndex == nil else { throw BrowserInteractionError.invalidRequest }
        case .select:
            guard control.kind == .select, request.text == nil,
                  control.options.contains(where: { $0.index == request.optionIndex && !$0.disabled }) else {
                throw BrowserInteractionError.invalidRequest
            }
        case .scroll: break
        }
    }
    private static func allowed(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 4096, url.scheme?.lowercased() == "https" else { return false }
        if case .allow = BrowserPolicy.evaluate(url) { return true }; return false
    }
}
