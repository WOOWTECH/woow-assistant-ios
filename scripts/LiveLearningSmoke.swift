import AssistantMemory
import AssistantModels
import AssistantSkills
import Foundation

/// Actual model calls with synthetic personal preferences; never household data.
/// No response bodies, user data, endpoint or credentials are printed.
@main struct LiveLearningSmoke {
    static func main() async {
        #if targetEnvironment(simulator)
        print("Live learning acceptance inside iOS Simulator")
        #elseif LEARNING_LOCAL_PROBE
        print("Local native learning probe; NOT an iOS Simulator acceptance run")
        #else
        print("FAIL: an iOS Simulator is required")
        exit(1)
        #endif
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let base = environment["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: base),
                  let model = environment["WOOW_MODEL_TEST_MODEL"],
                  let key = environment["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else { throw Check.failed }
            let client = HTTPChatModelClient()
            let configuration = ModelConfiguration(baseURL: url, model: model, maxOutputTokens: 2048)
            var memory = MemoryState()
            let utterance = "我最喜歡的顏色是琥珀色，這是我的長期喜好，請記住。"
            let input = MemoryExtractionInput(utterances: [utterance], conversationID: UUID().uuidString)
            let plan = try await MemoryExtractor(client: client).extract(input: input, state: memory,
                configuration: configuration, apiKey: key)
            guard plan.operationCount > 0 else { throw Check.failed }
            let notes = try memory.apply(plan: plan)
            guard !notes.isEmpty, memory.memories.contains(where: { $0.content.contains("琥珀") && $0.source.type == "user_said" }) else {
                throw Check.failed
            }
            print("PASS: real model extraction produced quote-validated persistent-memory candidates")
            guard let context = memory.context(goal: "喜歡的顏色").message else { throw Check.failed }
            let answer = try await client.complete(messages: [context,
                ModelMessage(role: "user", content: "我最喜歡什麼顏色？只回答顏色，使用繁體中文。")],
                configuration: configuration, apiKey: key)
            guard answer.contains("琥珀") else { throw Check.failed }
            print("PASS: new conversation recovered preference through actual memory context")
            var preferences = memory.preferences
            preferences.useMemory = false
            memory.setPreferences(preferences)
            guard memory.context(goal: "喜歡的顏色").message == nil else { throw Check.failed }
            let disabled = try await MemoryExtractor(client: client).extract(input: input, state: memory,
                configuration: configuration, apiKey: key)
            guard disabled.operationCount == 0 else { throw Check.failed }
            print("PASS: master switch excludes context and automatic extraction")

            var skills = SkillsState()
            let markdown = """
            ---
            name: parity-summary
            description: Reply format when the user asks for parity-summary.
            ---
            ## Entry
            The user explicitly asks for parity-summary.
            ## Steps
            Reply with exactly SKILL_ALIGNED and no other words.
            ## Pitfalls
            Do not append explanations or punctuation.
            ## Success criteria
            The reply is exactly SKILL_ALIGNED.
            ## When to stop
            Stop after the reply. Never call tools or change external state.
            """
            let draft = try skills.importMarkdown(markdown, availableToolNames: [])
            for value in ["https://example.invalid/api/webhook/not-a-real-secret",
                          "https://example.invalid/mcp?token=synthetic-value",
                          "https://dummy:synthetic@example.invalid", "A123456789"] {
                do {
                    _ = try SkillDocument.parse(markdown + "\n" + value, availableToolNames: [])
                    throw Check.failed
                } catch SkillsError.sensitiveContent { /* Expected; never a network request. */ }
            }
            print("PASS: skill import rejects capability URLs and synthetic identity data")
            guard skills.instructionContext(query: "parity-summary", availableToolNames: []).text.isEmpty else { throw Check.failed }
            _ = try skills.approveDraft(id: draft.id, availableToolNames: [])
            let reference = skills.instructionContext(query: "parity-summary", availableToolNames: [])
            guard !reference.text.isEmpty, !reference.grantsAuthorization else { throw Check.failed }
            let response = try await client.complete(messages: [ModelMessage(role: "user", content: reference.text),
                ModelMessage(role: "user", content: "Please use parity-summary to answer this message.")],
                configuration: configuration, apiKey: key)
            guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "SKILL_ALIGNED" else { throw Check.failed }
            guard skills.installed.first?.status == .trial else { throw Check.failed }
            try skills.suspend(name: "parity-summary")
            guard skills.instructionContext(query: "parity-summary", availableToolNames: []).text.isEmpty else { throw Check.failed }
            print("PASS: pending excluded; approved text skill affected real reply; disabled excluded; no false promotion")
            print("PASS: 3 bounded live model calls; no action-learning or device-control claim")
        } catch {
            print("FAIL: live learning contract did not pass (no response or credential logged)")
            exit(1)
        }
    }
    private enum Check: Error { case failed }
}
