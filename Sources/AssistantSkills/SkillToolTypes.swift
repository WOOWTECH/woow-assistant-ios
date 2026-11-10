#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import Foundation

public struct SkillToolLimits: Sendable {
    public let modelCalls: Int
    public let toolCalls: Int
    /// Cumulative model wait; time spent reading a human review is excluded.
    public let modelTime: Duration
    public init(modelCalls: Int = 12, toolCalls: Int = 10, modelTime: Duration = .seconds(180)) {
        self.modelCalls = modelCalls; self.toolCalls = toolCalls; self.modelTime = modelTime
    }
}

public enum SkillToolEvent: Sendable, Equatable {
    case requestingModel(Int)
    case executed(name: String, succeeded: Bool)
}

public enum SkillToolOutcome: Sendable {
    case review(SkillAuthoringSaveReview)
    case question(String)
    /// Model prose is never a save receipt. No write has occurred in this state.
    case finished(String)
}

public enum SkillToolError: String, Error, Equatable, Sendable, LocalizedError {
    case invalidLimits, invalidCommand, invalidState, sourceReadRequired, searchRequired
    case unknownReference, staleVersion, unsupportedFile, budgetExceeded, timedOut
    case modelFailed, modelRejected, modelInvalidResponse, cancelled, tooManyFailures
    public var errorDescription: String? {
        switch self {
        case .invalidLimits: return "技能協作的執行上限設定無效。"
        case .invalidCommand: return "模型回傳的技能工具格式不符，尚未儲存。"
        case .invalidState: return "本次技能協作狀態已變更，請重新開始。"
        case .sourceReadRequired: return "請先讀取本版本的技能編寫原文。"
        case .searchRequired: return "請先查詢是否已有相同用途的技能。"
        case .unknownReference: return "只能讀取本次技能目錄或查詢結果列出的技能。"
        case .staleVersion: return "更新版本與本次讀取的技能不符，尚未儲存。"
        case .unsupportedFile: return "只能讀取這份內建技能列出的原始附件。"
        case .budgetExceeded: return "本次技能協作已達回合或資料上限，尚未儲存。"
        case .timedOut: return "模型等待已達本次時間上限，尚未儲存。"
        case .modelFailed: return "無法連線至設定的模型，尚未儲存。"
        case .modelRejected: return "設定的模型服務拒絕要求，尚未儲存。"
        case .modelInvalidResponse: return "模型回覆不完整或格式無效，尚未儲存。"
        case .cancelled: return "已取消技能協作，尚未儲存。"
        case .tooManyFailures: return "技能草稿連續未通過檢查，尚未儲存；請調整要求後重新開始。"
        }
    }
}
#endif
