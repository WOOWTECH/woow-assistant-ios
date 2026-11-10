#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import CryptoKit
import Foundation

public enum TranscriptFormat: String, CaseIterable, Sendable, Codable {
    case summary, chapters, quotations, transcript, article
    public var title: String {
        switch self {
        case .summary: return "摘要"
        case .chapters: return "章節整理"
        case .quotations: return "逐字引文"
        case .transcript: return "全文整理"
        case .article: return "改寫成文章"
        }
    }
}

public enum TranscriptError: String, Error, Sendable, LocalizedError {
    case invalidSelection, unsupportedType, tooLarge, invalidEncoding, emptySource
    case approvalRequired, cancelled, readTimedOut, invalidCommand, invalidRange
    case incompleteCoverage, invalidEvidence, budgetExceeded, modelFailed, timedOut, contextChanged
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return "無法讀取所選檔案，或檔案不是一般檔案；不接受符號連結。"
        case .unsupportedType: return "請選取 UTF-8 的 txt、srt、vtt 或 md 文字檔。"
        case .tooLarge: return "文字檔超過 64 KiB 上限，請先分成較小的檔案。"
        case .invalidEncoding: return "檔案不是有效的 UTF-8 文字，或含有不支援的控制字元。"
        case .emptySource: return "所選檔案沒有可整理的文字。"
        case .approvalRequired: return "請先核對所選檔案並核准本次讀取。"
        case .cancelled: return "已停止本次整理，沒有新增記憶或技能。"
        case .readTimedOut: return "檔案提供者未在讀取期限內完成，尚未傳送給模型。"
        case .invalidCommand: return "模型回傳的工具格式無效，整理未完成。"
        case .invalidRange: return "模型要求的讀取範圍無效；只能依序重疊讀取核准的文字快照。"
        case .incompleteCoverage: return "模型尚未讀完全部文字，不能標示整理完成。"
        case .invalidEvidence: return "模型的引文或時間無法在已讀原文中逐字核對，整理未完成。"
        case .budgetExceeded: return "本次整理已達回合或資料上限，尚未完成。"
        case .modelFailed: return "設定的模型服務未完成要求，請檢查模型設定或連線。"
        case .timedOut: return "本次模型等待已達時間上限，尚未完成。"
        case .contextChanged: return "模型設定已變更，本次整理已停止；請重新確認目的服務。"
        }
    }
}

public struct TranscriptFileReview: Sendable, Identifiable {
    public let id: UUID
    public let filename: String
    public let maximumBytes = TranscriptSnapshot.maximumBytes
}

/// An immutable snapshot created only by the approved, coordinated file reader.
/// Never contains an executable path or a model-controlled URL.
public struct TranscriptSnapshot: Sendable {
    public static let maximumBytes = 64 * 1024
    public let id: UUID
    public let filename: String
    public let text: String
    public let sha256: String
    public let sourceKind: TranscriptSourceKind
    public let sourceURL: URL?
    public var byteCount: Int { bytes.count }
    let bytes: Data

    init(filename: String, data: Data, sourceKind: TranscriptSourceKind = .selectedFile, sourceURL: URL? = nil) throws {
        guard data.count <= Self.maximumBytes else { throw TranscriptError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw TranscriptError.invalidEncoding }
        // String(data:encoding:) may consume a BOM. Preserve every valid source
        // byte in our evidence instead of silently normalizing the snapshot.
        let text = String(decoding: data, as: UTF8.self)
        guard !text.unicodeScalars.contains(where: {
            ($0.value < 32 && ![9, 10, 13].contains($0.value)) || (0x7F...0x9F).contains($0.value)
        }) else { throw TranscriptError.invalidEncoding }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty else {
            throw TranscriptError.emptySource
        }
        id = UUID(); self.filename = filename; self.text = text; bytes = data
        self.sourceKind = sourceKind; self.sourceURL = sourceURL
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TranscriptRead: Sendable, Codable, Equatable {
    public let offset: Int
    public let length: Int
    public let text: String
    public var end: Int { offset + length }
}

public struct TranscriptEvidence: Sendable, Identifiable {
    public var id: String { "\(offset):\(quote.utf8.count)" }
    public let offset: Int
    public let quote: String
    /// Exact source timestamp, never a model-estimated or invented time.
    public let timestamp: String?
}

public struct TranscriptSection: Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let text: String
    public let evidence: [TranscriptEvidence]
}

public struct TranscriptResult: Sendable {
    public let format: TranscriptFormat
    public let title: String
    public let sections: [TranscriptSection]
    public let source: TranscriptSnapshot
    public let reads: [TranscriptRead]
    public let sourceRevision: String
    public let modelCalls: Int
}

/// Fixed diagnostic categories only; never contains a model-supplied field,
/// value, tool name, path, endpoint or reply excerpt.
public enum TranscriptCommandFailureReason: String, Error, Sendable, CaseIterable {
    case syntax, size, fields, action, tool, arguments
}

public enum TranscriptEvent: Sendable {
    case requestingModel(Int)
    case read(coveredBytes: Int, totalBytes: Int)
    case commandFormatRejected(reason: TranscriptCommandFailureReason, correctionIssued: Bool)
}

public struct TranscriptLimits: Sendable {
    public let modelCalls: Int
    public let modelTime: Duration
    public init(modelCalls: Int = 24, modelTime: Duration = .seconds(180)) {
        self.modelCalls = modelCalls; self.modelTime = modelTime
    }
}
#endif
