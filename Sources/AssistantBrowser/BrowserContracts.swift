import Foundation

public typealias BrowserTabID = UUID
public typealias GatewaySessionID = UUID

public enum BrowserProfile: String, Codable, Sendable, CaseIterable {
    case standard
    case privateBrowsing
}

public struct UploadGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tabID: BrowserTabID
    public let filename: String
    public let expiresAt: Date

    public init(id: UUID = UUID(), tabID: BrowserTabID, filename: String, expiresAt: Date) {
        self.id = id
        self.tabID = tabID
        self.filename = filename
        self.expiresAt = expiresAt
    }
}

public struct DownloadRequest: Codable, Sendable, Equatable {
    public let tabID: BrowserTabID
    public let suggestedFilename: String
    public let sourceURL: URL

    public init(tabID: BrowserTabID, suggestedFilename: String, sourceURL: URL) {
        self.tabID = tabID
        self.suggestedFilename = suggestedFilename
        self.sourceURL = sourceURL
    }
}

public struct DownloadResult: Codable, Sendable, Equatable {
    public let request: DownloadRequest
    public let temporaryURL: URL
    public let byteCount: Int64

    public init(request: DownloadRequest, temporaryURL: URL, byteCount: Int64) {
        self.request = request
        self.temporaryURL = temporaryURL
        self.byteCount = byteCount
    }
}

public struct VaultItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let filename: String
    public let byteCount: Int64
    public let createdAt: Date

    public init(id: UUID = UUID(), filename: String, byteCount: Int64, createdAt: Date = .now) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct PageSnapshot: Codable, Sendable, Equatable {
    public let url: URL
    public let title: String
    public let visibleText: String
    public let selectedText: String?
    public let capturedAt: Date

    public init(url: URL, title: String, visibleText: String, selectedText: String? = nil, capturedAt: Date = .now) {
        self.url = url
        self.title = title
        self.visibleText = visibleText
        self.selectedText = selectedText
        self.capturedAt = capturedAt
    }
}

public enum SafePageActionKind: String, Codable, Sendable, CaseIterable {
    case scroll
    case findInPage
    case openVisibleLink
    case fillPlainText
    case selectOption
}

public struct PageActionProposal: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tabID: BrowserTabID
    public let kind: SafePageActionKind
    public let summary: String
    public let requiresConfirmation: Bool
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        tabID: BrowserTabID,
        kind: SafePageActionKind,
        summary: String,
        requiresConfirmation: Bool,
        expiresAt: Date
    ) {
        self.id = id
        self.tabID = tabID
        self.kind = kind
        self.summary = summary
        self.requiresConfirmation = requiresConfirmation
        self.expiresAt = expiresAt
    }
}

public struct PageActionResult: Codable, Sendable, Equatable {
    public let succeeded: Bool
    public let summary: String

    public init(succeeded: Bool, summary: String) {
        self.succeeded = succeeded
        self.summary = summary
    }
}

public struct GatewaySession: Codable, Sendable, Equatable, Identifiable {
    public let id: GatewaySessionID
    public let createdAt: Date
    public let expiresAt: Date

    public init(id: GatewaySessionID = UUID(), createdAt: Date = .now, expiresAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct GatewaySessionRequest: Codable, Sendable, Equatable {
    public let startURL: URL
    public let reason: String

    public init(startURL: URL, reason: String) {
        self.startURL = startURL
        self.reason = reason
    }
}

public enum GatewayAction: Codable, Sendable, Equatable {
    case inspectPage
    case captureScreenshot
    case performApprovedWorkflow(name: String)
}

public struct GatewayResult: Codable, Sendable, Equatable {
    public let summary: String
    public let artifactReference: String?

    public init(summary: String, artifactReference: String? = nil) {
        self.summary = summary
        self.artifactReference = artifactReference
    }
}

@MainActor
public protocol BrowserTabManaging {
    func createTab(url: URL?, profile: BrowserProfile) async throws -> BrowserTabID
    func activate(_ id: BrowserTabID)
    func close(_ id: BrowserTabID) async
    func restoreWorkspace() async
}

public protocol BrowserVaulting: Sendable {
    func stageUpload(urls: [URL], tabID: BrowserTabID) async throws -> [UploadGrant]
    func allocateDownload(_ request: DownloadRequest) async throws -> URL
    func finalizeDownload(_ result: DownloadResult) async throws -> VaultItem
    func revokeGrants(for tabID: BrowserTabID) async
}

public protocol PageSnapshotExtracting: Sendable {
    func extract(from tabID: BrowserTabID, selection: String?) async throws -> PageSnapshot
}

public protocol PageActionExecuting: Sendable {
    func execute(_ proposal: PageActionProposal, confirmedByUser: Bool) async throws -> PageActionResult
}

public protocol BrowserGatewayServing: Sendable {
    func createSession(_ request: GatewaySessionRequest) async throws -> GatewaySession
    func perform(_ action: GatewayAction, in session: GatewaySessionID) async throws -> GatewayResult
    func cancel(session: GatewaySessionID) async
}
