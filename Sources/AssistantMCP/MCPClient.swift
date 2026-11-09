import Foundation

/// A foreground Streamable HTTP client. It starts no server, discovers no URLs,
/// performs no automatic retries, and persists no endpoint/session/arguments.
/// The 2024-11-05 version is accepted over this transport; legacy SSE endpoint
/// discovery, sampling, elicitation and unsolicited server requests are not enabled.
public actor MCPClient {
    private let endpoint: URL
    private let transport: MCPHTTPTransport
    private let timeout: Duration
    private var server: MCPServerInfo?
    private var sessionID: String?
    private var nextID = 0
    private var inFlight = false
    private var cancelOperation: (@Sendable () -> Void)?
    static let maximumPages = 32
    static let maximumItems = 10_000

    public init(endpoint: URL) {
        self.endpoint = endpoint
        transport = MCPHTTPTransport(configuration: .ephemeral)
        timeout = .seconds(60)
    }

    // Injection is internal so production clients always use an ephemeral session.
    init(endpoint: URL, configuration: URLSessionConfiguration, timeout: Duration = .seconds(60)) {
        self.endpoint = endpoint
        transport = MCPHTTPTransport(configuration: configuration)
        self.timeout = max(.milliseconds(1), min(timeout, .seconds(60)))
    }

    public func initialize() async throws -> MCPServerInfo {
        if !inFlight, let server = server { return server }
        return try await perform { deadline in try await self.initializeSession(deadline: deadline) }
    }

    public func listTools() async throws -> [MCPTool] {
        try await perform { deadline in
            let values = try await self.catalog("tools", deadline: deadline)
            return try values.map { value in
                guard let name = value["name"]?.stringValue, !name.isEmpty,
                      case .object? = value["inputSchema"], let schema = value["inputSchema"] else {
                    throw MCPError.invalidResponse
                }
                if let description = value["description"], description != .null,
                   description.stringValue == nil { throw MCPError.invalidResponse }
                return MCPTool(name: name, description: value["description"]?.stringValue, inputSchema: schema)
            }
        }
    }

    /// The caller must independently audit this allowlist. Server annotations
    /// (including readOnlyHint), model output and tool names are not authorization.
    /// No client can guarantee that an allowlisted server tool is actually read-only.
    public func callReadOnlyTool(name: String, arguments: JSONValue, allowlist: Set<String>) async throws -> JSONValue {
        guard allowlist.contains(name) else { throw MCPError.toolNotAllowed }
        return try await callAuthorizedTool(name: name, arguments: arguments)
    }

    /// Single, already-authorized invocation for trusted host integrations.
    /// The host must obtain consent for this exact name/arguments before calling;
    /// use MCPConversationRunner for model-generated proposals. Neither tool
    /// annotations nor this API's name establish consent. Never retries a call.
    public func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard !name.isEmpty, case .object = arguments else { throw MCPError.invalidRequest }
        return try await perform { deadline in
            try await self.requireCapability("tools")
            let reply = try await self.request("tools/call", params: .object([
                "name": .string(name), "arguments": arguments
            ]), deadline: deadline)
            guard let result = reply.result else { throw MCPError.invalidResponse }
            // Preserve content, structuredContent and isError. Tool errors are
            // application results; never convert their text into logged errors.
            return result
        }
    }

    public func listResources() async throws -> [MCPResource] {
        try await perform { deadline in
            let values = try await self.catalog("resources", deadline: deadline)
            return try values.map { value in
                guard let name = value["name"]?.stringValue, let uri = value["uri"]?.stringValue,
                      !name.isEmpty, !uri.isEmpty else { throw MCPError.invalidResponse }
                return MCPResource(uri: uri, name: name, mimeType: value["mimeType"]?.stringValue)
            }
        }
    }

    public func listPrompts() async throws -> [MCPPrompt] {
        try await perform { deadline in
            let values = try await self.catalog("prompts", deadline: deadline)
            return try values.map { value in
                guard let name = value["name"]?.stringValue, !name.isEmpty else { throw MCPError.invalidResponse }
                return MCPPrompt(name: name, description: value["description"]?.stringValue, arguments: value["arguments"])
            }
        }
    }

    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await perform { deadline in
            let values = try await self.catalog("resourceTemplates", capability: "resources",
                                                method: "resources/templates/list", deadline: deadline)
            return try values.map { value in
                guard let name = value["name"]?.stringValue, let uri = value["uriTemplate"]?.stringValue,
                      !name.isEmpty, !uri.isEmpty else { throw MCPError.invalidResponse }
                return MCPResourceTemplate(uriTemplate: uri, name: name, mimeType: value["mimeType"]?.stringValue)
            }
        }
    }

    public func readResource(uri: String) async throws -> JSONValue {
        guard !uri.isEmpty else { throw MCPError.invalidRequest }
        return try await perform { deadline in
            try await self.requireCapability("resources")
            let reply = try await self.request("resources/read", params: .object(["uri": .string(uri)]), deadline: deadline)
            guard let result = reply.result, case .array? = result["contents"] else { throw MCPError.invalidResponse }
            return result
        }
    }

    public func ping() async throws {
        try await perform { deadline in try await self.performPing(deadline: deadline) }
    }

    private func performPing(deadline: ContinuousClock.Instant) async throws {
        guard server != nil else { throw MCPError.notInitialized }
        let reply = try await request("ping", params: nil, deadline: deadline)
        guard case .object? = reply.result else { throw MCPError.invalidResponse }
    }

    /// Cancels local HTTP work. Cancellation does not promise remote tool rollback.
    /// No cancellation POST/retry is sent after a timeout or caller cancellation.
    public func cancel() { cancelOperation?() }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (ContinuousClock.Instant) async throws -> T) async throws -> T {
        guard !Task.isCancelled else { throw MCPError.cancelled }
        guard !inFlight else { throw MCPError.busy }
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw MCPError.invalidEndpoint }
        inFlight = true
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let worker = Task {
            try Task.checkCancellation()
            let result = try await body(deadline)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw MCPError.timedOut }
            return result
        }
        cancelOperation = { worker.cancel() }
        defer { inFlight = false; cancelOperation = nil }
        do {
            return try await withTaskCancellationHandler {
                return try await worker.value
            } onCancel: { worker.cancel() }
        } catch {
            let safe = MCPError.sanitized(error)
            // Expired sessions require explicit reinitialization; never replay a tool.
            if safe == .httpStatus(statusCode: 404), sessionID != nil { server = nil; sessionID = nil }
            throw safe
        }
    }

    private func initializeSession(deadline: ContinuousClock.Instant) async throws -> MCPServerInfo {
        sessionID = nil
        server = nil
        do {
            let reply = try await request("initialize", params: .object([
                "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("WoowAssistant-iOS"), "version": .string("0.1")])
            ]), deadline: deadline)
            guard let result = reply.result, let version = result["protocolVersion"]?.stringValue,
                  case .object(let capabilities)? = result["capabilities"],
                  result["serverInfo"]?["name"]?.stringValue != nil,
                  result["serverInfo"]?["version"]?.stringValue != nil else { throw MCPError.invalidResponse }
            guard ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version) else { throw MCPError.unsupportedVersion }
            guard capabilities.values.allSatisfy({ if case .object = $0 { return true }; return false }) else {
                throw MCPError.invalidResponse
            }
            let info = MCPServerInfo(protocolVersion: version, capabilities: Set(capabilities.keys))
            sessionID = reply.sessionID
            // Store provisional state only inside the serialized operation so the
            // notification receives the negotiated headers. Failure clears it.
            server = info
            _ = try await request("notifications/initialized", params: nil, notification: true, deadline: deadline)
            return info
        } catch { server = nil; sessionID = nil; throw error }
    }

    private func requireCapability(_ name: String) throws {
        guard let server = server else { throw MCPError.notInitialized }
        guard server.capabilities.contains(name) else { throw MCPError.capabilityUnavailable }
    }

    private func catalog(_ collection: String, capability: String? = nil, method: String? = nil,
                         deadline: ContinuousClock.Instant) async throws -> [JSONValue] {
        guard let server = server else { throw MCPError.notInitialized }
        guard server.capabilities.contains(capability ?? collection) else { return [] }
        var values: [JSONValue] = []
        var cursor: String?
        var seen = Set<String>()
        var bytes = 0
        for _ in 0..<Self.maximumPages {
            let params = cursor.map { JSONValue.object(["cursor": .string($0)]) } ?? .object([:])
            let reply = try await request(method ?? collection + "/list", params: params, deadline: deadline)
            bytes += reply.byteCount
            guard bytes <= MCPHTTPTransport.maximumResponseBytes else { throw MCPError.responseTooLarge }
            guard let result = reply.result, case .array(let page)? = result[collection] else { throw MCPError.invalidResponse }
            guard values.count + page.count <= Self.maximumItems else { throw MCPError.paginationLimit }
            values.append(contentsOf: page)
            guard let next = result["nextCursor"], next != .null else { return values }
            guard let nextCursor = next.stringValue, !nextCursor.isEmpty else { throw MCPError.invalidResponse }
            guard seen.insert(nextCursor).inserted else { throw MCPError.paginationLimit }
            cursor = nextCursor
        }
        throw MCPError.paginationLimit
    }

    private func request(_ method: String, params: JSONValue?, notification: Bool = false,
                         deadline: ContinuousClock.Instant) async throws -> MCPHTTPReply {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw MCPError.timedOut }
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(60, seconds))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("WoowAssistant/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(server?.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params = params { body["params"] = params }
        var id: String?
        if !notification { nextID += 1; id = String(nextID); body["id"] = .string(String(nextID)) }
        do { request.httpBody = try JSONEncoder().encode(JSONValue.object(body)) }
        catch { throw MCPError.invalidRequest }
        guard (request.httpBody?.count ?? 0) <= MCPHTTPTransport.maximumResponseBytes else { throw MCPError.invalidRequest }
        let reply = try await transport.send(request, expectedID: id, deadline: deadline)
        if method != "initialize", let received = reply.sessionID, received != sessionID { throw MCPError.invalidResponse }
        return reply
    }
}
