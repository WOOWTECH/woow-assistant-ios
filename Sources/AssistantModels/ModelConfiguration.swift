import Foundation

public struct ModelConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let maxOutputTokens: Int

    public init(baseURL: URL, model: String, maxOutputTokens: Int = 1024) {
        self.baseURL = baseURL
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ModelMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol ChatModelClient: Sendable {
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String
}

/// Optional text-delta capability. Finishing normally certifies a complete reply;
/// truncation, cancellation and provider errors must finish by throwing.
/// Structured tool flows continue using complete and their existing validators.
public protocol StreamingChatModelClient: ChatModelClient {
    func stream(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) -> AsyncThrowingStream<String, Error>
}

/// Deliberately excludes response bodies, credentials and endpoint URLs.
public enum HTTPChatModelError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case redirectRejected
    case httpStatus(Int)
    case invalidResponse
    case incompleteResponse
    case responseTooLarge
    case consumerTooSlow
    case timedOut
    case transportFailure

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Check the HTTPS endpoint, model, API key and output token limit (1–8192)."
        case .redirectRejected: return "The model endpoint attempted a redirect."
        case .httpStatus(let status): return "The model request failed (HTTP \(status))."
        case .invalidResponse: return "The model returned an invalid response."
        case .incompleteResponse: return "The model response ended before completion."
        case .responseTooLarge: return "The model response exceeded the size limit."
        case .consumerTooSlow: return "The model stream exceeded the pending output limit."
        case .timedOut: return "The model request exceeded its time limit."
        case .transportFailure: return "The model connection failed."
        }
    }
}
