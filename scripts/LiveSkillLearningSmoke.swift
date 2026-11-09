import AssistantModels
import AssistantSkills
import Foundation

/// Real model judge/drafter over SYNTHETIC executor evidence. This is NOT a
/// WebKit navigation/end-to-end browser test. No device/user data is accessed.
/// Secrets arrive only through the CI process environment; never print inputs,
/// generated content, endpoint, credentials or underlying error descriptions.
@main
struct LiveSkillLearningSmoke {
    static func main() async {
        #if targetEnvironment(simulator)
        print("Live skill learning: iOS Simulator; SYNTHETIC executor evidence, real model")
        #elseif SKILL_LEARNING_LOCAL_PROBE
        print("Local native skill learning probe; SYNTHETIC executor evidence, NOT WebKit/iOS acceptance")
        #else
        print("FAIL: iOS Simulator required unless explicitly built as a local probe")
        exit(1)
        #endif
        var phase = "configuration"
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let base = environment["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: base),
                  let model = environment["WOOW_MODEL_TEST_MODEL"], !model.isEmpty,
                  let key = environment["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else { throw Check.failed }
            let client = CountingClient()
            let configuration = ModelConfiguration(baseURL: url, model: model, maxOutputTokens: 2048)
            let toolNames: Set<String> = ["browser_open_link", "browser_inspect", "browser_find"]
            let pages = [
                "Plan: define the research question before choosing a source.",
                "Gather: follow the handbook links and collect relevant source material.",
                "Compare: compare the source material and identify agreements and differences.",
                "Check: verify each conclusion against the source material.",
                "Summarize: write a concise answer supported by the checked sources."
            ]
            let actions = pages.enumerated().map { index, result in
                SkillExecutedAction(id: "synthetic-\(index)", toolName: "browser_open_link", kind: .navigation,
                    arguments: ["url": "https://handbook.example.invalid/phase/\(index)"],
                    result: result, succeeded: true,
                    observedURL: URL(string: "https://handbook.example.invalid/phase/\(index)"))
            }
            let goal = "Read all five linked handbook phases and report their names and purpose in order."
            let answer = pages.joined(separator: "\n")
            var state = SkillsState()
            phase = "judge-and-drafter"
            let assessment = try await SkillLearningService(client: client).assess(
                goal: goal, answer: answer, actions: actions, state: state,
                availableToolNames: toolNames, configuration: configuration, apiKey: key)
            // Only bounded enum/count diagnostics. No generated reason, response,
            // configuration, credential or source text is written to the log.
            print("Assessment diagnostics: outcome=\(assessment.judgment.outcome.rawValue); citations=\(assessment.judgment.citations.count); uniqueActions=\(assessment.evidence.successfulActionCount); observedURLs=\(actions.filter { $0.observedURL != nil }.count); modelCalls=\(await client.count)")
            guard assessment.judgment.outcome == .done, !assessment.judgment.citations.isEmpty,
                  assessment.evidence.successfulActionCount == 5, assessment.proposal != nil else {
                // Skip reasons are fixed enum codes, not provider/user content.
                print("FAIL: assessment category \(assessment.skipReason?.rawValue ?? "unexpected-result")")
                throw Check.failed
            }
            let calls = await client.count
            guard calls == 2 else { throw Check.failed }
            print("PASS: real model judged done with exact synthetic-result citations; drafter returned validated Markdown")
            phase = "pending-and-review"
            guard state.installed.isEmpty, state.pending.isEmpty,
                  let pending = try state.apply(assessment, availableToolNames: toolNames),
                  pending.source == .learned, state.installed.isEmpty, state.pending.count == 1,
                  state.search(query: pending.name).isEmpty else { throw Check.failed }
            let encoded = try JSONEncoder().encode(state)
            guard try JSONDecoder().decode(SkillsState.self, from: encoded) == state else { throw Check.failed }
            let approved = try state.approveDraft(id: pending.id, availableToolNames: toolNames)
            guard approved.status == .trial, approved.outcomes.isEmpty else { throw Check.failed }
            print("PASS: proposal stayed pending; explicit approval entered trial without false success promotion")
            print("PASS: 2 bounded real model calls; SYNTHETIC trajectory only, no live browser/executor claim")
        } catch {
            print("FAIL: skill learning phase \(phase); no content or credential logged")
            exit(1)
        }
    }

    private enum Check: Error { case failed }
    private actor CountingClient: ChatModelClient {
        private(set) var count = 0
        private let client = HTTPChatModelClient()
        func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
            count += 1
            return try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
        }
    }
}
