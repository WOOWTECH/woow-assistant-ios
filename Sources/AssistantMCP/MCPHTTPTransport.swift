import Foundation

struct MCPHTTPReply: Sendable {
    let result: JSONValue?
    let sessionID: String?
    let byteCount: Int
}

final class MCPHTTPTransport: @unchecked Sendable {
    static let maximumResponseBytes = 4 * 1024 * 1024
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        // Configuration is copied by URLSession. Even injected test configurations
        // cannot enable credential, cookie, cache or redirect persistence here.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest, expectedID: String?, deadline: ContinuousClock.Instant) async throws -> MCPHTTPReply {
        do {
            return try await withThrowingTaskGroup(of: MCPHTTPReply.self) { group in
                group.addTask { try await self.receive(request, expectedID: expectedID) }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw MCPError.timedOut
                }
                defer { group.cancelAll() }
                guard let reply = try await group.next() else { throw MCPError.cancelled }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw MCPError.timedOut }
                return reply
            }
        } catch { throw MCPError.sanitized(error) }
    }

    private func receive(_ request: URLRequest, expectedID: String?) async throws -> MCPHTTPReply {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request, delegate: MCPRejectRedirects())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw MCPError.redirectRejected }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.httpStatus(statusCode: http.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw MCPError.responseTooLarge }
        let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if let sessionID = sessionID {
            guard !sessionID.isEmpty, sessionID.utf8.count <= 4096,
                  sessionID.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw MCPError.invalidResponse }
        }
        let isSSE = http.mimeType?.lowercased() == "text/event-stream"
        if expectedID == nil {
            guard http.statusCode == 202 else { throw MCPError.invalidResponse }
        } else {
            guard http.statusCode == 200, isSSE || http.mimeType?.lowercased() == "application/json" else {
                throw MCPError.invalidResponse
            }
        }
        return try await withTaskCancellationHandler {
            var data = Data()
            var count = 0
            var parser = MCPSSEParser(expectedID: expectedID ?? "")
            for try await byte in bytes {
                try Task.checkCancellation()
                count += 1
                guard count <= Self.maximumResponseBytes else { throw MCPError.responseTooLarge }
                guard expectedID != nil else { throw MCPError.invalidResponse }
                if isSSE {
                    if let result = try parser.append(byte) {
                        return MCPHTTPReply(result: result, sessionID: sessionID, byteCount: count)
                    }
                } else { data.append(byte) }
            }
            try Task.checkCancellation()
            if let expectedID = expectedID {
                guard !isSSE, let result = try MCPRPCResponse.result(data, expectedID: expectedID) else {
                    throw MCPError.invalidResponse
                }
                return MCPHTTPReply(result: result, sessionID: sessionID, byteCount: count)
            }
            return MCPHTTPReply(result: nil, sessionID: sessionID, byteCount: count)
        } onCancel: { bytes.task.cancel() }
    }
}

final class MCPRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
