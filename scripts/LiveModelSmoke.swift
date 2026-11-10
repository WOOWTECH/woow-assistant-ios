import AssistantModels
import Foundation

/// Manual-only live transport test. Secrets arrive through the simulator process
/// environment, never command-line arguments, project files, screenshots or logs.
@main
struct LiveModelSmoke {
    static func main() async {
        #if !targetEnvironment(simulator)
        print("FAIL: this live acceptance executable must run inside iOS Simulator")
        exit(1)
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: base),
              let model = environment["WOOW_MODEL_TEST_MODEL"], !model.isEmpty,
              let key = environment["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else {
            print("FAIL: missing live test configuration")
            exit(1)
        }
        let configuration = ModelConfiguration(baseURL: url, model: model, maxOutputTokens: 64)
        let messages = [ModelMessage(role: "user", content: "Reply with exactly WOOW_OK and nothing else.")]
        let client = HTTPChatModelClient()
        do {
            let response = try await client.complete(messages: messages, configuration: configuration, apiKey: key)
            guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "WOOW_OK" else {
                print("FAIL: native JSON reply did not match the expected marker")
                exit(1)
            }
            print("PASS: iOS Simulator native URLSession JSON completion")
            var output = ""
            var chunks = 0
            for try await delta in client.stream(messages: messages, configuration: configuration, apiKey: key) {
                output += delta
                chunks += 1
                guard output.utf8.count <= 8192 else {
                    print("FAIL: unexpected live response size")
                    exit(1)
                }
            }
            guard chunks > 0, output.trimmingCharacters(in: .whitespacesAndNewlines) == "WOOW_OK" else {
                print("FAIL: native streaming reply did not match the expected marker")
                exit(1)
            }
            print("PASS: iOS Simulator native SSE completion; content chunks: \(chunks)")
            print("PASS: 2 live native model tests; no response bodies or credentials logged")
        } catch {
            // Do not print arbitrary provider error descriptions, URLs or payloads.
            print("FAIL: native model request failed; category=\(failureCode(error))")
            exit(1)
        }
        #endif
    }

    /// Only fixed categories. Never include NSError metadata, URLs, response
    /// bodies, underlying descriptions or credentials in the public job log.
    static func failureCode(_ error: Error) -> String {
        guard let error = error as? HTTPChatModelError else {
            return error is CancellationError ? "cancelled" : "unknown"
        }
        switch error {
        case .httpStatus(let status):
            if status == 401 || status == 403 { return "authentication_rejected" }
            if status == 429 { return "rate_limited" }
            if (500...599).contains(status) { return "provider_server_error" }
            return "http_rejected"
        case .invalidConfiguration: return "configuration"
        case .redirectRejected: return "redirect_rejected"
        case .invalidResponse: return "invalid_response"
        case .incompleteResponse: return "incomplete_response"
        case .responseTooLarge: return "response_too_large"
        case .consumerTooSlow: return "consumer_too_slow"
        case .timedOut: return "timed_out"
        case .transportFailure: return "transport_failed"
        }
    }
}
