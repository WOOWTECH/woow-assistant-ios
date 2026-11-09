#if DEBUG
import AssistantMCP
import Foundation

/// Deterministic in-process server. No URLSession or production endpoint is used.
actor UITestMCPFixture: MCPDiscovering {
    private var count = 0
    func initialize() async throws -> MCPServerInfo {
        MCPServerInfo(protocolVersion: "2025-03-26", capabilities: ["tools", "resources"])
    }
    func listTools() async throws -> [MCPTool] {
        [MCPTool(name: "fixture_echo", inputSchema: .object([
            "type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])]),
            "required": .array([.string("text")]), "additionalProperties": .bool(false)
        ]))]
    }
    func listResources() async throws -> [MCPResource] {
        [MCPResource(uri: "fixture://guide", name: "Fixture guide", mimeType: "text/plain")]
    }
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard name == "fixture_echo", let text = arguments["text"]?.stringValue else { throw MCPError.invalidRequest }
        count += 1
        return .object([
            "isError": .bool(text == "error"),
            "content": .array([.object(["type": .string("text"),
                "text": .string("FIXTURE_CALL_\(count): \(text)")])])
        ])
    }
    func readResource(uri: String) async throws -> JSONValue {
        guard uri == "fixture://guide" else { throw MCPError.invalidRequest }
        try Task.checkCancellation()
        return .object(["contents": .array([.object([
            "uri": .string(uri), "mimeType": .string("text/plain"), "text": .string("FIXTURE_RESOURCE_OK")
        ])])])
    }
    func cancel() async {}
}
#endif
