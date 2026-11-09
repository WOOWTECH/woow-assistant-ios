import Foundation
#if !MCP_SMOKE
@testable import AssistantMCP
#endif

/// The same deterministic checks run under XCTest and the CLT standalone runner.
enum MCPClientChecks {
    struct Failed: Error { let check: String }
    struct Counter {
        var count = 0
        mutating func expect(_ condition: Bool, _ label: String) throws {
            count += 1
            guard condition else { throw Failed(check: label) }
        }
    }

    static let tool: JSONValue = .object([
        "name": .string("read_state"), "inputSchema": .object(["type": .string("object")]),
        "annotations": .object(["readOnlyHint": .bool(true)])
    ])

    static func initialized(_ body: JSONValue, version: String = "2025-03-26",
                            capabilities: [String] = ["tools", "resources", "prompts", "logging"],
                            session: String? = nil) throws -> MCPProtocolFixture.Reply? {
        if body["method"] == .string("initialize") {
            var reply = try MCPProtocolFixture.Reply.result(.object([
                "protocolVersion": .string(version),
                "capabilities": .object(Dictionary(uniqueKeysWithValues: capabilities.map { ($0, .object([:])) })),
                "serverInfo": .object(["name": .string("Fixture"), "version": .string("1")])
            ]), request: body)
            reply.headers["Mcp-Session-Id"] = session
            return reply
        }
        if body["method"] == .string("notifications/initialized") { return .init(status: 202) }
        return nil
    }

    static func expectError(_ error: MCPError, _ operation: () async throws -> Void) async throws -> Int {
        do { try await operation() }
        catch let actual as MCPError {
            guard actual == error else { throw Failed(check: "unexpected typed error category") }
            return 1
        }
        catch { throw Failed(check: "unsanitized error") }
        throw Failed(check: "expected error was not thrown")
    }

    static func handshake() async throws -> Int {
        var checks = Counter()
        for version in ["2024-11-05", "2025-03-26", "2025-06-18"] {
            for session in [nil, "fixture-session"] as [String?] {
                let scenario = MCPProtocolFixture.Scenario { _, body, _ in
                    if let reply = try initialized(body, version: version, session: session) { return reply }
                    return try .result(.object([:]), request: body)
                }
                let endpoint = MCPProtocolFixture.register(scenario)
                defer { MCPProtocolFixture.remove(endpoint) }
                let client = MCPClient(endpoint: endpoint, configuration: MCPProtocolFixture.configuration())
                let info = try await client.initialize()
                try checks.expect(info.protocolVersion == version, "negotiated version")
                try checks.expect(info.capabilities == ["tools", "resources", "prompts", "logging"], "capabilities")
                _ = try await client.initialize()
                try checks.expect(scenario.records.count == 2, "idempotent initialization")
                try await client.ping()
                let records = scenario.records
                try checks.expect(records.count == 3, "one initialize, one notification, one ping")
                try checks.expect(records[0].1["params"]?["protocolVersion"] == .string("2025-03-26"), "requested version")
                try checks.expect(records[1].1["id"] == nil, "notification has no id")
                try checks.expect(records[1].1["method"] == .string("notifications/initialized"), "initialized notification")
                for (index, record) in records.enumerated() {
                    try checks.expect(record.0.url == endpoint, "webhook path and query unchanged")
                    try checks.expect(record.0.httpMethod == "POST", "POST only")
                    try checks.expect(record.0.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream", "Accept")
                    try checks.expect(record.0.value(forHTTPHeaderField: "User-Agent") == "WoowAssistant/0.1", "User-Agent")
                    try checks.expect(record.0.timeoutInterval <= 60, "bounded timeout")
                    try checks.expect(record.0.value(forHTTPHeaderField: "Mcp-Session-Id") == (index == 0 ? nil : session), "session header")
                    try checks.expect(record.0.value(forHTTPHeaderField: "MCP-Protocol-Version") == (index == 0 ? nil : version), "version header")
                }
            }
        }
        return checks.count
    }

    static func catalogsAndTools() async throws -> Int {
        var checks = Counter()
        let longText = String(repeating: "大型工具 schema 🏠", count: 8000)
        let largeTool: JSONValue = .object([
            "name": .string("large"), "inputSchema": .object(["type": .string("object"), "description": .string(longText)])
        ])
        let result: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
                                        "structuredContent": .object(["value": .number(2)]), "isError": .bool(false)])
        let scenario = MCPProtocolFixture.Scenario { _, body, _ in
            if let reply = try initialized(body) { return reply }
            switch body["method"]?.stringValue {
            case "tools/list":
                if body["params"]?["cursor"] == nil {
                    return try .result(.object(["tools": .array([largeTool]), "nextCursor": .string("second")]), request: body, sse: true)
                }
                return try .result(.object(["tools": .array([tool])]), request: body)
            case "tools/call": return try .result(result, request: body, sse: true)
            case "resources/list": return try .result(.object(["resources": .array([.object([
                "name": .string("guide"), "uri": .string("ha://guide"), "mimeType": .string("text/plain")
            ])])]), request: body)
            case "resources/templates/list": return try .result(.object(["resourceTemplates": .array([.object([
                "name": .string("entity"), "uriTemplate": .string("ha://entity/{id}")
            ])])]), request: body)
            case "resources/read": return try .result(.object(["contents": .array([.object(["text": .string("guide text")])])]), request: body)
            case "prompts/list": return try .result(.object(["prompts": .array([])]), request: body)
            default: throw Failed(check: "unexpected request")
            }
        }
        let endpoint = MCPProtocolFixture.register(scenario)
        defer { MCPProtocolFixture.remove(endpoint) }
        let client = MCPClient(endpoint: endpoint, configuration: MCPProtocolFixture.configuration())
        _ = try await client.initialize()
        let tools = try await client.listTools()
        try checks.expect(tools.map(\.name) == ["large", "read_state"], "SSE and JSON pagination")
        try checks.expect(tools[0].inputSchema["description"] == .string(longText), "single SSE frame over 64 KiB")
        try checks.expect(scenario.records[3].1["params"]?["cursor"] == .string("second"), "opaque cursor sent")
        let count = scenario.records.count
        var errors = try await expectError(.toolNotAllowed) {
            _ = try await client.callReadOnlyTool(name: "read_state", arguments: .object([:]), allowlist: [])
        }
        try checks.expect(scenario.records.count == count, "readOnlyHint never authorizes request")
        errors += try await expectError(.toolNotAllowed) {
            _ = try await client.callReadOnlyTool(name: "READ_STATE", arguments: .object([:]), allowlist: ["read_state"])
        }
        let args: JSONValue = .object(["limit": .number(3)])
        let response = try await client.callReadOnlyTool(name: "read_state", arguments: args, allowlist: ["read_state"])
        try checks.expect(response == result, "arbitrary structured tool result")
        try checks.expect(scenario.records.last?.1["params"]?["arguments"] == args, "caller arguments preserved")
        let resources = try await client.listResources()
        try checks.expect(resources.first?.uri == "ha://guide", "resource listing")
        let templates = try await client.listResourceTemplates()
        try checks.expect(templates.first?.uriTemplate == "ha://entity/{id}", "template listing")
        let contents = try await client.readResource(uri: "ha://guide")
        try checks.expect(contents["contents"] != nil, "resource contents")
        try checks.expect(scenario.records.last?.1["params"]?["uri"] == .string("ha://guide"), "resource read remains MCP request")
        let prompts = try await client.listPrompts()
        try checks.expect(prompts.isEmpty, "empty prompt catalog")
        return checks.count + errors
    }

    static func capabilitiesAndLimits() async throws -> Int {
        var checks = Counter()
        var errors = 0
        let noCapabilities = MCPProtocolFixture.Scenario { _, body, _ in
            guard let reply = try initialized(body, capabilities: []) else { throw Failed(check: "capability bypass") }
            return reply
        }
        let endpoint = MCPProtocolFixture.register(noCapabilities)
        defer { MCPProtocolFixture.remove(endpoint) }
        let client = MCPClient(endpoint: endpoint, configuration: MCPProtocolFixture.configuration())
        errors += try await expectError(.notInitialized) { _ = try await client.listTools() }
        _ = try await client.initialize()
        let tools = try await client.listTools(), resources = try await client.listResources()
        let prompts = try await client.listPrompts(), templates = try await client.listResourceTemplates()
        try checks.expect(tools.isEmpty && resources.isEmpty && prompts.isEmpty && templates.isEmpty, "absent capabilities yield empty catalogs")
        errors += try await expectError(.capabilityUnavailable) { _ = try await client.readResource(uri: "ha://guide") }
        errors += try await expectError(.capabilityUnavailable) {
            _ = try await client.callReadOnlyTool(name: "read_state", arguments: .object([:]), allowlist: ["read_state"])
        }
        try checks.expect(noCapabilities.records.count == 2, "no unsupported capability requests")
        for mode in 0..<3 {
            let scenario = MCPProtocolFixture.Scenario { _, body, index in
                if let reply = try initialized(body) { return reply }
                let values = mode == 2 ? Array(repeating: tool, count: MCPClient.maximumItems + 1) : []
                return try .result(.object(["tools": .array(values), "nextCursor": .string(mode == 0 ? "same" : String(index))]), request: body)
            }
            let url = MCPProtocolFixture.register(scenario)
            defer { MCPProtocolFixture.remove(url) }
            let limited = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration())
            _ = try await limited.initialize()
            errors += try await expectError(.paginationLimit) { _ = try await limited.listTools() }
            try checks.expect(scenario.records.count <= MCPClient.maximumPages + 2, "bounded page count")
        }
        return checks.count + errors
    }

    static func parserAndErrors() async throws -> Int {
        var checks = Counter()
        var errors = 0
        let arbitrary: JSONValue = .object(["array": .array([.null, .bool(true), .number(Decimal(string: "9007199254740993")!)]),
                                            "nested": .object(["name": .string("繁體中文")])])
        let roundtrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(arbitrary))
        try checks.expect(roundtrip == arbitrary, "JSON shapes and exact large integer roundtrip")
        var parser = MCPSSEParser(expectedID: "id")
        let frames = "\u{feff}: comment\rdata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\r\r" +
            "data: {\"jsonrpc\":\"2.0\",\n" + "data: \"id\":\"id\",\"result\":null}\n\n"
        var parsed: JSONValue?
        for byte in frames.utf8 { if let value = try parser.append(byte) { parsed = value } }
        try checks.expect(parsed == .null, "CR LF multiline notification and null result")
        let failureBodies: [(String, MCPError)] = [
            ("{\"jsonrpc\":\"2.0\",\"id\":\"wrong\",\"result\":{}}", .responseIDMismatch),
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", .responseIDMismatch),
            ("{\"jsonrpc\":\"2.0\",\"id\":\"id\",\"result\":{},\"error\":{}}", .invalidResponse),
            ("{\"jsonrpc\":\"2.0\",\"id\":\"id\",\"error\":{\"code\":-32601,\"message\":\"secret\",\"data\":\"secret\"}}", .rpcFailure(rpcCode: -32601)),
            ("{\"jsonrpc\":\"2.0\",\"id\":\"server\",\"method\":\"sampling/createMessage\"}", .unsupportedServerRequest),
            ("{broken-secret", .invalidResponse)
        ]
        for (body, expected) in failureBodies {
            errors += try await expectError(expected) { _ = try MCPRPCResponse.result(Data(body.utf8), expectedID: "id") }
        }
        for (status, expected) in [(301, MCPError.redirectRejected), (307, .redirectRejected), (401, .httpStatus(statusCode: 401)), (500, .httpStatus(statusCode: 500))] {
            let scenario = MCPProtocolFixture.Scenario { _, _, _ in
                .init(status: status, headers: ["Location": "https://other.invalid/secret"], chunks: [Data("secret-body".utf8)])
            }
            let url = MCPProtocolFixture.register(scenario)
            defer { MCPProtocolFixture.remove(url) }
            let client = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration())
            errors += try await expectError(expected) { _ = try await client.initialize() }
            try checks.expect(scenario.records.count == 1, "no redirect or error retries")
            try checks.expect(!expected.localizedDescription.contains("secret"), "safe error description")
        }
        for (reply, expected) in [
            (MCPProtocolFixture.Reply(headers: ["Content-Type": "application/json", "Content-Length": "4194305"]), MCPError.responseTooLarge),
            (.init(chunks: [Data(repeating: 32, count: MCPHTTPTransport.maximumResponseBytes + 1)]), .responseTooLarge),
            (.init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: {}\n".utf8)]), .invalidResponse),
            (.init(headers: ["Content-Type": "text/html"], chunks: [Data("secret".utf8)]), .invalidResponse),
            (.init(failure: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "secret"])), .transportFailure)
        ] {
            let scenario = MCPProtocolFixture.Scenario { _, _, _ in reply }
            let url = MCPProtocolFixture.register(scenario)
            defer { MCPProtocolFixture.remove(url) }
            let client = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration())
            errors += try await expectError(expected) { _ = try await client.initialize() }
        }
        let badVersion = MCPProtocolFixture.Scenario { _, body, _ in try initialized(body, version: "future")! }
        let url = MCPProtocolFixture.register(badVersion)
        defer { MCPProtocolFixture.remove(url) }
        let unsupported = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration())
        errors += try await expectError(.unsupportedVersion) { _ = try await unsupported.initialize() }
        try checks.expect(badVersion.records.count == 1, "no initialized notification after failed negotiation")
        for address in ["http://fixture.invalid/secret", "https://user:secret@fixture.invalid/", "https://fixture.invalid/#secret"] {
            let invalid = MCPClient(endpoint: URL(string: address)!, configuration: MCPProtocolFixture.configuration())
            errors += try await expectError(.invalidEndpoint) { _ = try await invalid.initialize() }
        }
        return checks.count + errors
    }

    static func deadlinesAndCancellation() async throws -> Int {
        var checks = Counter()
        var errors = 0
        for holdBefore in [true, false] {
            let scenario = MCPProtocolFixture.Scenario { _, _, _ in
                .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data(": still waiting\n\n".utf8)],
                      holdBeforeHeaders: holdBefore, holdAfterBody: true)
            }
            let url = MCPProtocolFixture.register(scenario)
            defer { MCPProtocolFixture.remove(url) }
            let client = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration(), timeout: .milliseconds(100))
            errors += try await expectError(.timedOut) { _ = try await client.initialize() }
            try checks.expect(scenario.records.count == 1, "timeout never retries")
        }
        let pages = MCPProtocolFixture.Scenario { _, body, index in
            if let reply = try initialized(body) { return reply }
            var reply = try MCPProtocolFixture.Reply.result(.object(["tools": .array([]), "nextCursor": .string(String(index))]), request: body)
            reply.delay = 0.04
            return reply
        }
        let pageURL = MCPProtocolFixture.register(pages)
        defer { MCPProtocolFixture.remove(pageURL) }
        let limited = MCPClient(endpoint: pageURL, configuration: MCPProtocolFixture.configuration(), timeout: .milliseconds(100))
        _ = try await limited.initialize()
        errors += try await expectError(.timedOut) { _ = try await limited.listTools() }
        try checks.expect(pages.records.count <= 5, "one total pagination deadline")
        for explicitCancel in [false, true] {
            let scenario = MCPProtocolFixture.Scenario { _, _, _ in .init(holdBeforeHeaders: true) }
            let url = MCPProtocolFixture.register(scenario)
            defer { MCPProtocolFixture.remove(url) }
            let client = MCPClient(endpoint: url, configuration: MCPProtocolFixture.configuration())
            let worker = Task { try await client.initialize() }
            for _ in 0..<500 {
                if !scenario.records.isEmpty { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try checks.expect(scenario.records.count == 1, "cancellable request started")
            errors += try await expectError(.busy) { _ = try await client.initialize() }
            if explicitCancel { await client.cancel() } else { worker.cancel() }
            errors += try await expectError(.cancelled) { _ = try await worker.value }
        }
        return checks.count + errors
    }
}
