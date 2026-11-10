import Foundation

public enum ChatContextWindowError: Error, LocalizedError, Equatable, Sendable {
    case invalidHistory
    case currentTurnTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidHistory:
            return "聊天歷史不是完整的使用者與助理回合，請開啟新對話後再試。"
        case .currentTurnTooLarge:
            return "這次訊息與參考內容超過傳送上限，請縮短訊息或參考內容。"
        }
    }
}

/// A value-only window for model input, not a change to displayed conversation
/// history. Keep the complete current context and prompt, then the most recent
/// contiguous complete turns. Content is never rewritten or split.
public struct ChatContextWindow: Sendable {
    public let messages: [ModelMessage]
    public let retainedTurns: Int
    public let omittedTurns: Int

    public init(history: [ModelMessage], context: [ModelMessage], prompt: String) throws {
        // Validate even the history that will be omitted. Otherwise a malformed
        // role sequence could silently be reinterpreted as different turns.
        guard history.count.isMultiple(of: 2) else { throw ChatContextWindowError.invalidHistory }
        for index in stride(from: 0, to: history.count, by: 2) {
            guard history[index].role == "user", history[index + 1].role == "assistant" else {
                throw ChatContextWindowError.invalidHistory
            }
        }

        // These limits cover the returned messages' content bytes, not JSON
        // serialization or any instructions later prepended by another layer.
        guard context.count < 32 else { throw ChatContextWindowError.currentTurnTooLarge }
        var remainingBytes = 64 * 1024
        for message in context {
            let bytes = message.content.utf8.count
            guard bytes <= remainingBytes else { throw ChatContextWindowError.currentTurnTooLarge }
            remainingBytes -= bytes
        }
        let promptBytes = prompt.utf8.count
        guard promptBytes <= remainingBytes else { throw ChatContextWindowError.currentTurnTooLarge }
        remainingBytes -= promptBytes
        var remainingSlots = 32 - context.count - 1
        var firstRetainedIndex = history.count
        while firstRetainedIndex >= 2 && remainingSlots >= 2 {
            let index = firstRetainedIndex - 2
            let userBytes = history[index].content.utf8.count
            guard userBytes <= remainingBytes else { break }
            let assistantBytes = history[index + 1].content.utf8.count
            guard assistantBytes <= remainingBytes - userBytes else { break }
            remainingBytes -= userBytes + assistantBytes
            remainingSlots -= 2
            firstRetainedIndex = index
        }

        retainedTurns = (history.count - firstRetainedIndex) / 2
        omittedTurns = firstRetainedIndex / 2
        messages = Array(history[firstRetainedIndex...]) + context
            + [ModelMessage(role: "user", content: prompt)]
    }
}
