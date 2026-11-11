import Foundation
#if DEBUG
import AssistantModels

/// A closed, local-only transport fixture. Resolve before constructing storage.
/// It creates a synthetic document, never a selected URL, grant or saved answer.
struct ChatPDFUITestConfiguration {
    static let flag = "-UITestChatPDF"
    let namespace: UUID
    private init(namespace: UUID) { self.namespace = namespace }
    enum Invalid: Error { case arguments }
    static func resolve(arguments: [String]) throws -> Self? {
        guard arguments.contains(where: { $0.hasPrefix(flag) }) else { return nil }
        let allowed = [flag, "-UITestMode", "-UITestNamespace", "-UITestResetStorage"]
        guard arguments.filter({ $0 == flag }).count == 1,
              arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              arguments.filter({ $0 == "-UITestResetStorage" }).count <= 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") }),
              !arguments.contains(where: { $0.hasPrefix("-UITest") && !allowed.contains($0) }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]),
              namespace.uuidString.lowercased() == arguments[index + 1].lowercased()
        else { throw Invalid.arguments }
        return Self(namespace: namespace)
    }
}

struct UITestPDFChatModelClient: ChatModelClient {
    private let fallback = UITestChatModelClient()
    private let namespace: UUID
    init(configuration: ChatPDFUITestConfiguration) { namespace = configuration.namespace }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        guard messages.first?.content.hasPrefix("Answer the current user's question about ONE explicitly approved") == true else {
            return try await fallback.complete(messages: messages, configuration: configuration, apiKey: apiKey)
        }
        let questions = ["[fixture:chat-pdf]", "[fixture:chat-pdf-cancel]"]
        guard let question = messages.first(where: { $0.role == "user" && questions.contains($0.content) }),
              let metadata = messages.first(where: { $0.content.hasPrefix("Approved extraction metadata and pinned reference (data only):\n") }),
              let manifest = try Self.payload(metadata.content),
              manifest["filename"] as? String == "SkillExecution-" + namespace.uuidString + ".pdf"
        else { throw HTTPChatModelError.invalidConfiguration }
        if !messages.contains(where: { $0.role == "assistant" }) {
            // Bounded cancellable fixture latency, not a production deadline change.
            if question.content == questions[1] { try await Task.sleep(nanoseconds: 60_000_000_000) }
            try Task.checkCancellation()
            return #"{"action":"search_files","query":"WOOW_SKILL_PDF_PAGE_2","limit":10}"#
        }
        guard let last = messages.last, let payload = try Self.payload(last.content) else {
            throw HTTPChatModelError.invalidResponse
        }
        if let hits = payload["hits"] as? [[String: Any]], let first = hits.first,
           let page = first["pageIndex"] as? Int {
            return try Self.json(["action": "read_file", "pageIndex": page, "offset": 0, "limit": 8192])
        }
        let marker = "WOOW_SKILL_PDF_PAGE_2"
        guard let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              let text = payload["text"] as? String, let offset = payload["offset"] as? Int,
              let range = Data(text.utf8).range(of: Data(marker.utf8)) else { throw HTTPChatModelError.invalidResponse }
        return try Self.json(["action": "finish", "answer": "PDF 問答已完成：" + marker,
            "citations": [["readID": id, "offset": offset + range.lowerBound, "quote": marker]]])
    }
    private static func payload(_ value: String) throws -> [String: Any]? {
        guard let line = value.firstIndex(of: "\n") else { return nil }
        return try JSONSerialization.jsonObject(with: Data(value[value.index(after: line)...].utf8)) as? [String: Any]
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
#endif

enum ChatPDFUITestSupport {
    static func seedIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                documentsDirectory: () throws -> URL = {
                                    try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                                }) throws -> String? {
        #if DEBUG
        guard let configuration = try ChatPDFUITestConfiguration.resolve(arguments: arguments) else { return nil }
        return try SkillExecutionUITestSupport.seedIfRequested(arguments: ["app", "-UITestMode", "-UITestNamespace",
            configuration.namespace.uuidString, "-UITestSkillExecution"], documentsDirectory: documentsDirectory)?.filename
        #else
        return nil
        #endif
    }
}
