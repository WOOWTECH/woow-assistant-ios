import CryptoKit
import Foundation

/// Source catalog only. Nothing in a bundled document is execution authority.
public enum SkillCatalogError: String, Error, Sendable, LocalizedError {
    case unavailable, invalidCatalog, notFound, alreadyAdded
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "內建技能目錄暫時無法讀取。"
        case .invalidCatalog: return "內建技能資源驗證失敗；未匯入任何內容。"
        case .notFound: return "找不到這個內建技能。"
        case .alreadyAdded: return "此文字版已有草稿或已匯入；請到待確認或技能清單管理。"
        }
    }
}

public enum SkillCatalogRequirement: String, Codable, Sendable, CaseIterable {
    case settingsAutomation, androidControl, legacyWebTools, workspaceFiles
    case python, shell, fileExport, crossOriginResearch, accountAccess, externalSend, skillMutationTools

    public var title: String {
        switch self {
        case .settingsAutomation: return "可允許模型調整本 App 外觀；不提供模型、金鑰或手機操作設定"
        case .androidControl: return "Android／其他 App 操作：不在 iOS 範圍"
        case .legacyWebTools: return "原版網頁工具：iOS 提供受控研究與 DOM 操作，非完整瀏覽器能力對齊"
        case .workspaceFiles: return "可選取 PDF、文字與字幕；未提供原版的一般工作區"
        case .python: return "原始 PDF 腳本需另行設定服務；本機不執行 Python"
        case .shell: return "Shell／桌面命令執行：未提供"
        case .fileExport: return "原版檔案產生與分享工具：未提供"
        case .crossOriginResearch: return "原版跨網站自動研究：未提供"
        case .accountAccess: return "原版跨 App 帳號／收件匣讀取：未提供；MCP 能力另依伺服器與授權"
        case .externalSend: return "原版跨 App 訊息傳送：未提供；MCP 工具須另行核准"
        case .skillMutationTools: return "模型可查詢、讀取並提出技能草稿；儲存須由你核准"
        }
    }
}

/// Entire original UTF-8 file, including final newline. Scripts are inert text.
public struct SkillCatalogDocument: Decodable, Equatable, Sendable, Identifiable {
    public let path: String
    public let content: String
    public let sha256: String
    public var id: String { path }
    public var sourceURL: URL {
        URL(string: BundledSkillCatalog.repository)!
            .appendingPathComponent("blob").appendingPathComponent(BundledSkillCatalog.pinnedCommit)
            .appendingPathComponent(path)
    }
    public var executable: Bool { false }
}

public struct SkillCatalogEntry: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let aliases: [String]
    public let requirements: [SkillCatalogRequirement]
    public let adaptationScope: String
    public let adaptationName: String
    public let adaptationMarkdown: String
    public let original: SkillCatalogDocument
    public let assets: [SkillCatalogDocument]
    public var originalExecutionSupported: Bool { false }
    public var readiness: String {
        switch id {
        case "configure-mika": return "可調整本 App 外觀；原版能力未完整支援"
        case "skill-authoring": return "可請模型編寫並核准儲存；原版能力未完整支援"
        case "documents": return "可選取 PDF 擷取文字；原版能力未完整支援"
        case "content-transcribe": return "可整理核准的文字、字幕與網頁文字；原版能力未完整支援"
        default: return "可匯入 iOS 文字改寫；原版能力未完整支援"
        }
    }
}

/// Mika 0c172724's six bundled skills, their three supporting files, LICENSE and
/// NOTICE are copied verbatim into the immutable resource. iOS adaptations are
/// separately labeled modifications. Never feed the raw archive to execution.
public struct BundledSkillCatalog: Sendable {
    public static let repository = "https://github.com/wangzan101/Mika"
    public static let pinnedCommit = "0c172724f3f0c96f7345262588072f6e95db1138"
    public static let entryIDs = ["configure-mika", "content-transcribe", "documents", "info-research", "messaging", "skill-authoring"]
    // Pin the complete manifest as well as verifying every embedded file hash.
    // Resource changes require deliberate review; network/downloaded catalogs are
    // not accepted by this loader and cannot silently change readiness or prose.
    private static let resourceHash = "e7389c7c3b39d0dd0bb133d0d7f8733cd1ecfbd3a2e2eb4b66d28b43850a9176"
    public let entries: [SkillCatalogEntry]
    public let license: SkillCatalogDocument
    public let notice: SkillCatalogDocument

    public static func bundled() throws -> BundledSkillCatalog {
        try load(data: bundledData())
    }

    static func bundledData() throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: SkillCatalogBundleToken.self)
        #endif
        guard let url = bundle.url(forResource: "MikaBundledSkills", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw SkillCatalogError.unavailable }
        return data
    }

    public static func load(data: Data) throws -> BundledSkillCatalog {
        guard data.count <= 256 * 1024, digest(data) == resourceHash,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1, archive.repository == repository, archive.commit == pinnedCommit,
              archive.entries.map(\.id) == entryIDs,
              archive.license.path == "LICENSE", archive.notice.path == "NOTICE" else {
            throw SkillCatalogError.invalidCatalog
        }
        let documents = [archive.license, archive.notice] + archive.entries.flatMap { [$0.original] + $0.assets }
        guard documents.count == 11, Set(documents.map(\.path)).count == documents.count,
              documents.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= 64 * 1024 &&
                  digest(Data($0.content.utf8)) == $0.sha256 }) else { throw SkillCatalogError.invalidCatalog }
        for entry in archive.entries {
            let prefix = "core/src/main/resources/skills/" + entry.id + "/"
            guard entry.original.path == prefix + "SKILL.md",
                  entry.assets.allSatisfy({ $0.path.hasPrefix(prefix) && !$0.path.contains("..") }),
                  entry.adaptationName == "ios-mika-" + entry.id, !entry.requirements.isEmpty,
                  let adaptation = try? SkillDocument.parse(entry.adaptationMarkdown, availableToolNames: []),
                  adaptation.name == entry.adaptationName, adaptation.referencedToolNames.isEmpty,
                  adaptation.frontMatter["learned_from"] == nil,
                  adaptation.frontMatter["source"] == nil else { throw SkillCatalogError.invalidCatalog }
        }
        return BundledSkillCatalog(entries: archive.entries, license: archive.license, notice: archive.notice)
    }

    public func entry(id: String) -> SkillCatalogEntry? { entries.first { $0.id == id } }

    /// Search original/full adaptation text and supporting content, not just names.
    public func search(_ query: String) -> [SkillCatalogEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let text = ([entry.id, entry.title, entry.summary, entry.adaptationScope,
                         entry.original.content, entry.adaptationMarkdown] + entry.aliases +
                        entry.requirements.map(\.title) + entry.assets.map(\.content)).joined(separator: "\n")
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Adds only the labeled text adaptation. Reuses existing import/approval/
    /// trial lifecycle and never replaces a user's pending or installed version.
    @discardableResult
    public func stageAdaptation(id: String, into state: inout SkillsState,
                                now: Date = Date(), draftID: UUID = UUID()) throws -> SkillDraft {
        guard let entry = entry(id: id) else { throw SkillCatalogError.notFound }
        guard !state.pending.contains(where: { $0.name == entry.adaptationName }),
              !state.installed.contains(where: { $0.name == entry.adaptationName }) else { throw SkillCatalogError.alreadyAdded }
        return try state.importMarkdown(entry.adaptationMarkdown, availableToolNames: [],
                                        builtinNames: Set(Self.entryIDs), now: now, draftID: draftID)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Archive: Decodable {
        let version: Int
        let repository: String
        let commit: String
        let license: SkillCatalogDocument
        let notice: SkillCatalogDocument
        let entries: [SkillCatalogEntry]
    }
}

private final class SkillCatalogBundleToken: NSObject {}
