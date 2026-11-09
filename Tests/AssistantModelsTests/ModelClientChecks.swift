import Foundation
@testable import AssistantModels

/// Shared by XCTest and a standalone Swift harness on hosts without XCTest.
enum ModelClientChecks {
    struct CheckFailure: Error { let name: String }
    struct Checks {
        var count = 0
        mutating func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            count += 1
            if !condition() { throw CheckFailure(name: name) }
        }
        mutating func error(_ expected: HTTPChatModelError, _ operation: () throws -> Void) throws {
            do { try operation(); throw CheckFailure(name: "Expected sanitized error") }
            catch let error as HTTPChatModelError { try expect(error == expected, "Wrong sanitized error") }
        }
    }
    static let fakeKey = "unit-test-key-not-a-real-credential"
    static let messages = [ModelMessage(role: "user", content: "你好 🏡")]
    static let completion = Data(#"{"choices":[{"message":{"role":"assistant","content":"你好 🏡"},"finish_reason":"stop"}]}"#.utf8)
    static let textEvent = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好 🏡\"},\"finish_reason\":null}]}\n\n"
    static let stopEvent = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
    static let doneEvent = "data: [DONE]\n\n"

    static func requestContract() throws -> Int {
        var checks = Checks()
        let paths = [("", "/v1/chat/completions"), ("/", "/v1/chat/completions"),
                     ("/v1", "/v1/chat/completions"), ("/v1///", "/v1/chat/completions"),
                     ("/v1/chat/completions/", "/v1/chat/completions"),
                     ("/gateway/v1", "/gateway/v1/chat/completions")]
        for (path, expected) in paths {
            let configuration = ModelConfiguration(baseURL: URL(string: "https://fixture.invalid\(path)")!, model: " test-model ")
            for stream in [false, true] {
                let request = try HTTPChatModelClient.request(messages: messages, configuration: configuration, apiKey: fakeKey, stream: stream)
                try checks.expect(request.url?.path == expected, "Exactly one completion suffix")
                try checks.expect(request.httpMethod == "POST", "POST")
                try checks.expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)", "Authorization")
                try checks.expect(request.value(forHTTPHeaderField: "User-Agent") == "WoowAssistant/0.1", "Descriptive user agent")
                try checks.expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON content type")
                try checks.expect(request.value(forHTTPHeaderField: "Accept") == (stream ? "text/event-stream" : "application/json"), "Accept")
                try checks.expect(request.timeoutInterval == 90, "90 second timeout")
                try checks.expect(!request.httpShouldHandleCookies, "No cookies")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try checks.expect(body["model"] as? String == "test-model", "Model field")
                try checks.expect(body["stream"] as? Bool == stream, "Stream field")
                try checks.expect(body["max_tokens"] as? Int == 1024, "Default output limit")
                try checks.expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "你好 🏡"]], "Messages")
                try checks.expect(body.count == 4, "Only agreed fields")
            }
        }
        for tokens in [1, 64, 8192] {
            for stream in [false, true] {
                let configuration = ModelConfiguration(baseURL: URL(string: "https://fixture.invalid/v1")!, model: "test", maxOutputTokens: tokens)
                let request = try HTTPChatModelClient.request(messages: messages, configuration: configuration, apiKey: fakeKey, stream: stream)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try checks.expect(body["max_tokens"] as? Int == tokens, "Explicit output limit")
            }
        }
        for endpoint in ["http://fixture.invalid/v1", "https://user@fixture.invalid/v1", "https://user:pass@fixture.invalid/v1",
                         "https://fixture.invalid/v1?", "https://fixture.invalid/v1?key=x", "https://fixture.invalid/v1#", "file:///v1", "/v1"] {
            try checks.error(.invalidConfiguration) {
                _ = try HTTPChatModelClient.request(messages: messages, configuration: .init(baseURL: URL(string: endpoint)!, model: "test"), apiKey: fakeKey, stream: false)
            }
        }
        for (model, key, tokens) in [(" ", fakeKey, 64), ("test", " ", 64), ("test", "bad\nkey", 64),
                                     ("test", fakeKey, 0), ("test", fakeKey, -1), ("test", fakeKey, 8193)] {
            try checks.error(.invalidConfiguration) {
                _ = try HTTPChatModelClient.request(messages: messages, configuration: .init(baseURL: URL(string: "https://fixture.invalid")!, model: model, maxOutputTokens: tokens), apiKey: key, stream: false)
            }
        }
        return checks.count
    }

    static func parserContract() throws -> Int {
        var checks = Checks()
        let roleEvent = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n"
        let usageEvent = "data: {\"choices\":[],\"usage\":{\"total_tokens\":64}}\n\n"
        let multiline = "data: {\"choices\":\n" + "data: [{\"index\":0,\"delta\":{\"content\":\"你好 🏡\"}}]}\n\n"
        for newline in ["\n", "\r\n", "\r"] {
            for event in [textEvent, multiline] {
                var parser = ChatSSEParser()
                var text = ""
                let bytes = Data(("\u{FEFF}: heartbeat\n\n" + roleEvent + event + stopEvent + usageEvent + doneEvent).replacingOccurrences(of: "\n", with: newline).utf8)
                for byte in bytes { if let delta = try parser.append(byte) { text += delta } }
                try parser.finish()
                try checks.expect(parser.done, "DONE reached")
                try checks.expect(text == "你好 🏡", "Unicode and newline fidelity")
            }
        }
        let invalid: [(Data, HTTPChatModelError)] = [
            (Data(textEvent.utf8), .incompleteResponse),
            (Data((textEvent + stopEvent + "data: [DONE]").utf8), .incompleteResponse),
            (Data((textEvent + doneEvent).utf8), .incompleteResponse),
            (Data(doneEvent.utf8), .incompleteResponse),
            (Data("data: {not-json}\n\n".utf8), .invalidResponse),
            (Data([100, 97, 116, 97, 58, 32, 0xFF, 10, 10]), .invalidResponse),
            (Data("event: error\ndata: {}\n\n".utf8), .invalidResponse),
            (Data("data: {\"choices\":[]}\n\n".utf8), .invalidResponse),
            (Data((textEvent + stopEvent.replacingOccurrences(of: "stop", with: "length")).utf8), .incompleteResponse),
            (Data((textEvent + stopEvent + textEvent + doneEvent).utf8), .invalidResponse),
            (Data(textEvent.replacingOccurrences(of: "\"index\":0", with: "\"index\":1").utf8), .invalidResponse),
            (Data(repeating: 65, count: ChatSSEParser.maximumEventBytes + 1), .responseTooLarge)
        ]
        for (bytes, expected) in invalid {
            try checks.error(expected) {
                var parser = ChatSSEParser()
                for byte in bytes { _ = try parser.append(byte) }
                try parser.finish()
            }
        }
        try checks.error(.responseTooLarge) {
            var parser = ChatSSEParser()
            // Small heartbeat events must still count against the aggregate budget.
            let heartbeat = Array((":" + String(repeating: "x", count: 1021) + "\n\n").utf8)
            for _ in 0...4096 { for byte in heartbeat { _ = try parser.append(byte) } }
        }
        return checks.count
    }

    static func completionTransport() async throws -> Int {
        var checks = Checks()
        let fixture = ModelProtocolFixture.Scenario(chunks: [completion])
        let base = ModelProtocolFixture.register(fixture)
        let session = ModelProtocolFixture.session()
        defer { session.invalidateAndCancel(); ModelProtocolFixture.remove(base) }
        let result = try await HTTPChatModelClient(session: session).complete(messages: messages, configuration: .init(baseURL: base, model: "test", maxOutputTokens: 64), apiKey: fakeKey)
        try checks.expect(result == "你好 🏡", "Complete Unicode content")
        try checks.expect(fixture.requestCount == 1, "Exactly one request")
        try checks.expect(fixture.lastRequest?.value(forHTTPHeaderField: "User-Agent") == "WoowAssistant/0.1", "Transport user agent")
        for (status, mime, body, expected) in [
            (401, "application/json", completion, HTTPChatModelError.httpStatus(401)),
            (403, "application/json", completion, .httpStatus(403)),
            (429, "application/json", completion, .httpStatus(429)),
            (500, "application/json", completion, .httpStatus(500)),
            (302, "text/html", Data(), .redirectRejected),
            (200, "text/html", completion, .invalidResponse),
            (200, "application/json", Data("RAW_BODY_\(fakeKey)".utf8), .invalidResponse),
            (200, "application/json", Data(#"{"choices":[]}"#.utf8), .incompleteResponse),
            (200, "application/json", Data(#"{"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]}"#.utf8), .incompleteResponse),
            (200, "application/json", Data(#"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#.utf8), .invalidResponse),
            (200, "application/json", Data(repeating: 65, count: ChatSSEParser.maximumResponseBytes + 1), .responseTooLarge)
        ] {
            let failed = ModelProtocolFixture.Scenario(status: status, mime: mime, chunks: [body])
            let url = ModelProtocolFixture.register(failed)
            defer { ModelProtocolFixture.remove(url) }
            do {
                _ = try await HTTPChatModelClient(session: session).complete(messages: messages, configuration: .init(baseURL: url, model: "test"), apiKey: fakeKey)
                throw CheckFailure(name: "Expected completion failure")
            } catch let error as HTTPChatModelError {
                try checks.expect(error == expected, "Completion failure category")
                try checks.expect(!error.localizedDescription.contains(fakeKey), "Error excludes key")
                try checks.expect(!error.localizedDescription.contains("RAW_BODY_"), "Error excludes raw body")
                try checks.expect(!error.localizedDescription.contains(url.absoluteString), "Error excludes URL")
            }
            try checks.expect(failed.requestCount == 1, "Failures never retry")
        }
        let unsafe = URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "RAW_BODY_\(fakeKey)", NSURLErrorFailingURLStringErrorKey: base.absoluteString])
        let failed = ModelProtocolFixture.Scenario(failure: unsafe)
        let url = ModelProtocolFixture.register(failed)
        defer { ModelProtocolFixture.remove(url) }
        do {
            _ = try await HTTPChatModelClient(session: session).complete(messages: messages, configuration: .init(baseURL: url, model: "test"), apiKey: fakeKey)
            throw CheckFailure(name: "Expected transport failure")
        } catch let error as HTTPChatModelError {
            try checks.expect(error == .transportFailure, "Transport failure is sanitized")
            try checks.expect(!error.localizedDescription.contains(fakeKey), "Transport error excludes raw text")
        }
        return checks.count
    }

    static func streamingTransport() async throws -> Int {
        var checks = Checks()
        let session = ModelProtocolFixture.session()
        defer { session.invalidateAndCancel() }
        let streamBytes = Data((textEvent + stopEvent + doneEvent).utf8)
        for chunkSize in [1, 2, 7, streamBytes.count] {
            let chunks = stride(from: 0, to: streamBytes.count, by: chunkSize).map { Data(streamBytes[$0..<min($0 + chunkSize, streamBytes.count)]) }
            let fixture = ModelProtocolFixture.Scenario(mime: "text/event-stream; charset=utf-8", chunks: chunks)
            let base = ModelProtocolFixture.register(fixture)
            defer { ModelProtocolFixture.remove(base) }
            var result = ""
            for try await text in HTTPChatModelClient(session: session).stream(messages: messages, configuration: .init(baseURL: base, model: "test", maxOutputTokens: 64), apiKey: fakeKey) {
                result += text
            }
            try checks.expect(result == "你好 🏡", "Streaming survives transport boundaries")
            try checks.expect(fixture.requestCount == 1, "One streaming request")
            try checks.expect(fixture.lastRequest?.value(forHTTPHeaderField: "Accept") == "text/event-stream", "Streaming accept")
        }
        for (body, expected) in [(textEvent, HTTPChatModelError.incompleteResponse), ("data: bad-json\n\n", .invalidResponse), (textEvent + doneEvent, .incompleteResponse)] {
            let fixture = ModelProtocolFixture.Scenario(mime: "text/event-stream", chunks: [Data(body.utf8)])
            let base = ModelProtocolFixture.register(fixture)
            defer { ModelProtocolFixture.remove(base) }
            do {
                for try await _ in HTTPChatModelClient(session: session).stream(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey) {}
                throw CheckFailure(name: "Truncated/malformed stream must fail")
            } catch let error as HTTPChatModelError { try checks.expect(error == expected, "Stream failure category") }
            try checks.expect(fixture.requestCount == 1, "No streaming retries")
        }
        return checks.count
    }

    static func deadlinesAndCancellation() async throws -> Int {
        var checks = Checks()
        let session = ModelProtocolFixture.session()
        defer { session.invalidateAndCancel() }
        for beforeHeaders in [true, false] {
            for streaming in [false, true] {
                let fixture = ModelProtocolFixture.Scenario(mime: streaming ? "text/event-stream" : "application/json", holdBeforeHeaders: beforeHeaders, holdAfterBody: true)
                let base = ModelProtocolFixture.register(fixture)
                defer { ModelProtocolFixture.remove(base) }
                let client = HTTPChatModelClient(session: session, timeoutNanoseconds: 50_000_000)
                let start = Date()
                do {
                    if streaming {
                        for try await _ in client.stream(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey) {}
                    } else {
                        _ = try await client.complete(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey)
                    }
                    throw CheckFailure(name: "Deadline must fail")
                } catch let error as HTTPChatModelError { try checks.expect(error == .timedOut, "Whole request deadline") }
                try checks.expect(Date().timeIntervalSince(start) < 2, "Bounded deadline")
                try await wait { fixture.stopCount > 0 }
                try checks.expect(fixture.stopCount > 0, "Timeout cancels underlying request")
                try checks.expect(fixture.requestCount == 1, "Timeout never retries")
            }
        }
        for beforeHeaders in [true, false] {
            for streaming in [false, true] {
                let fixture = ModelProtocolFixture.Scenario(mime: streaming ? "text/event-stream" : "application/json", holdBeforeHeaders: beforeHeaders, holdAfterBody: true)
                let base = ModelProtocolFixture.register(fixture)
                defer { ModelProtocolFixture.remove(base) }
                let client = HTTPChatModelClient(session: session)
                let work = Task {
                    if streaming {
                        for try await _ in client.stream(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey) {}
                    } else {
                        _ = try await client.complete(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey)
                    }
                    try Task.checkCancellation()
                }
                try await wait { beforeHeaders ? fixture.requestCount > 0 : fixture.bodyDelivered }
                work.cancel()
                do { try await work.value; throw CheckFailure(name: "Cancellation must not succeed") }
                catch is CancellationError { try checks.expect(true, "Cancellation exposed safely") }
                try await wait { fixture.stopCount > 0 }
                try checks.expect(fixture.stopCount > 0, "Cancellation stops underlying request")
                try checks.expect(fixture.requestCount == 1, "Cancellation never retries")
            }
        }
        return checks.count
    }

    static func slowConsumerAndRedirectPolicy() async throws -> Int {
        var checks = Checks()
        let session = ModelProtocolFixture.session()
        defer { session.invalidateAndCancel() }
        let fixture = ModelProtocolFixture.Scenario(mime: "text/event-stream", chunks: [Data((String(repeating: textEvent, count: 300) + stopEvent + doneEvent).utf8)], holdAfterBody: true)
        let base = ModelProtocolFixture.register(fixture)
        defer { ModelProtocolFixture.remove(base) }
        let stream = HTTPChatModelClient(session: session).stream(messages: messages, configuration: .init(baseURL: base, model: "test"), apiKey: fakeKey)
        // The producer cancels the held-open request after overflowing its queue.
        // Wait for that observable event instead of assuming a parsing speed.
        try await wait { fixture.stopCount > 0 }
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            throw CheckFailure(name: "Slow consumer must not lose text silently")
        } catch let error as HTTPChatModelError { try checks.expect(error == .consumerTooSlow, "Bounded output buffer") }
        try checks.expect(count == 256, "Exactly bounded pending deltas")
        let request = URLRequest(url: base)
        let task = session.dataTask(with: request) // Never resumed.
        var denied = false
        RejectModelRedirects().urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: base, statusCode: 307, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) {
            denied = $0 == nil
        }
        task.cancel()
        try checks.expect(denied, "Redirect callback rejects destination")
        return checks.count
    }

    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure(name: "Fixture did not reach expected state")
    }
}

#if MODEL_CLIENT_HARNESS
@main enum ModelClientHarness {
    static func main() async {
        do {
            var total = 0
            let request = try ModelClientChecks.requestContract()
            total += request; print("request: \(request)")
            let parser = try ModelClientChecks.parserContract()
            total += parser; print("parser: \(parser)")
            let completion = try await ModelClientChecks.completionTransport()
            total += completion; print("completion: \(completion)")
            let streaming = try await ModelClientChecks.streamingTransport()
            total += streaming; print("streaming: \(streaming)")
            let cancellation = try await ModelClientChecks.deadlinesAndCancellation()
            total += cancellation; print("deadline/cancellation: \(cancellation)")
            let bounds = try await ModelClientChecks.slowConsumerAndRedirectPolicy()
            total += bounds; print("backpressure/redirect: \(bounds)")
            print("PASS \(total) assertions; all requests intercepted; no live calls")
        } catch let error as ModelClientChecks.CheckFailure {
            print("FAIL: \(error.name)"); exit(1)
        } catch {
            print("FAIL: unexpected safe-error category \(type(of: error))"); exit(1)
        }
    }
}
#endif
