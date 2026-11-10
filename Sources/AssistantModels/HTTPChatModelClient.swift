import Foundation

public struct HTTPChatModelClient: StreamingChatModelClient {
    private let session: URLSession
    private let timeoutNanoseconds: UInt64
    private static let maximumTimeout: UInt64 = 90_000_000_000

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.init(session: URLSession(configuration: configuration))
    }

    public init(session: URLSession) {
        self.init(session: session, timeoutNanoseconds: Self.maximumTimeout)
    }

    // Shorter deadlines let deterministic tests exercise timeouts; never exceeds 90s.
    init(session: URLSession, timeoutNanoseconds: UInt64) {
        self.session = session
        self.timeoutNanoseconds = min(timeoutNanoseconds, Self.maximumTimeout)
    }

    public func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        do {
            let request = try Self.request(messages: messages, configuration: configuration, apiKey: apiKey, stream: false)
            return try await bounded {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request, delegate: RejectModelRedirects())
                defer { bytes.task.cancel() }
                try Self.validate(response, stream: false)
                return try await withTaskCancellationHandler {
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < ChatSSEParser.maximumResponseBytes else {
                            throw HTTPChatModelError.responseTooLarge
                        }
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    let response = try JSONDecoder().decode(Completion.self, from: data)
                    guard let choice = response.choices.first, choice.finish_reason == "stop" else {
                        throw HTTPChatModelError.incompleteResponse
                    }
                    guard !choice.message.content.isEmpty else { throw HTTPChatModelError.invalidResponse }
                    return choice.message.content
                } onCancel: {
                    bytes.task.cancel()
                }
            }
        } catch { throw Self.sanitized(error) }
    }

    /// Yields text deltas (not accumulated text). Slow consumers fail rather than lose text.
    public func stream(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let worker = Task {
                do {
                    let request = try Self.request(messages: messages, configuration: configuration, apiKey: apiKey, stream: true)
                    try await bounded {
                        try Task.checkCancellation()
                        let (bytes, response) = try await session.bytes(for: request, delegate: RejectModelRedirects())
                        defer { bytes.task.cancel() }
                        try Self.validate(response, stream: true)
                        try await withTaskCancellationHandler {
                            var parser = ChatSSEParser()
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                if let text = try parser.append(byte) {
                                    switch continuation.yield(text) {
                                    case .enqueued: break
                                    case .dropped: throw HTTPChatModelError.consumerTooSlow
                                    case .terminated: throw CancellationError()
                                    @unknown default: throw HTTPChatModelError.consumerTooSlow
                                    }
                                }
                                if parser.done { break }
                            }
                            try Task.checkCancellation()
                            try parser.finish()
                        } onCancel: {
                            bytes.task.cancel()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.sanitized(error))
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    private func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw HTTPChatModelError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }

    static func request(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String, stream: Bool) throws -> URLRequest {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !key.isEmpty, (1...8192).contains(configuration.maxOutputTokens),
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw HTTPChatModelError.invalidConfiguration
        }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1" }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.percentEncodedPath = path
        guard let endpoint = parts.url else { throw HTTPChatModelError.invalidConfiguration }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WoowAssistant/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages, stream: stream,
                                                               max_tokens: configuration.maxOutputTokens))
        return request
    }

    private static func validate(_ response: URLResponse, stream: Bool) throws {
        guard let response = response as? HTTPURLResponse else { throw HTTPChatModelError.invalidResponse }
        if (300..<400).contains(response.statusCode) { throw HTTPChatModelError.redirectRejected }
        guard (200..<300).contains(response.statusCode) else { throw HTTPChatModelError.httpStatus(response.statusCode) }
        let expected = stream ? "text/event-stream" : "application/json"
        guard response.mimeType?.lowercased() == expected else { throw HTTPChatModelError.invalidResponse }
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let known = error as? HTTPChatModelError { return known }
        if let network = error as? URLError {
            if network.code == .cancelled { return CancellationError() }
            if network.code == .timedOut { return HTTPChatModelError.timedOut }
            return HTTPChatModelError.transportFailure
        }
        if error is DecodingError { return HTTPChatModelError.invalidResponse }
        return HTTPChatModelError.transportFailure
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ModelMessage]
        let stream: Bool
        let max_tokens: Int
    }
    private struct Completion: Decodable { let choices: [Choice] }
    private struct Choice: Decodable {
        let message: ModelMessage
        let finish_reason: String?
    }
}

final class RejectModelRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
