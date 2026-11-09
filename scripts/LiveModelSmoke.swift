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
            print("FAIL: native model request failed (\(String(describing: type(of: error))))")
            exit(1)
        }
        #endif
    }
}
