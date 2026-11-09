import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number):
            guard !number.isNaN else { throw MCPError.invalidRequest }
            try value.encode(number)
        case .bool(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }
}

public struct MCPServerInfo: Sendable, Equatable {
    public let protocolVersion: String
    public let capabilities: Set<String>

    public init(protocolVersion: String, capabilities: Set<String>) {
        self.protocolVersion = protocolVersion; self.capabilities = capabilities
    }
}

public struct MCPTool: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public struct MCPResource: Codable, Sendable, Equatable {
    public let uri: String
    public let name: String
    public let mimeType: String?

    public init(uri: String, name: String, mimeType: String? = nil) {
        self.uri = uri; self.name = name; self.mimeType = mimeType
    }
}

public struct MCPPrompt: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let arguments: JSONValue?
}

public struct MCPResourceTemplate: Sendable, Equatable {
    public let uriTemplate: String
    public let name: String
    public let mimeType: String?
}

/// Errors intentionally contain only fixed categories and HTTP/RPC numeric codes.
/// Never attach an endpoint, session, request arguments, response body or underlying NSError.
public enum MCPError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint, invalidRequest, invalidResponse, unsupportedVersion
    case notInitialized, busy, capabilityUnavailable, toolNotAllowed
    case responseIDMismatch, unsupportedServerRequest, paginationLimit, responseTooLarge
    case redirectRejected, timedOut, cancelled, transportFailure
    case httpStatus(statusCode: Int)
    case rpcFailure(rpcCode: Int)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "MCP HTTP status \(code)."
        case .rpcFailure(let code): return "MCP RPC error \(code)."
        default: return "MCP request failed: \(String(describing: self))."
        }
    }

    static func sanitized(_ error: Error) -> MCPError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let known = error as? MCPError { return known }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            if urlError.code == .timedOut { return .timedOut }
        }
        return .transportFailure
    }
}
