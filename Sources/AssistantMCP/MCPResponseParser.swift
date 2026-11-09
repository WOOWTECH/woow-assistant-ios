import Foundation

/// Incremental SSE parsing with the same 4 MiB bound as JSON responses. There is
/// deliberately no small line/frame cap: a tools/list result can be one large event.
struct MCPSSEParser {
    let expectedID: String
    private var line = Data()
    private var eventData = Data()
    private var hasData = false
    private var afterCR = false
    private var firstLine = true
    private var received = 0

    init(expectedID: String) { self.expectedID = expectedID }

    mutating func append(_ byte: UInt8) throws -> JSONValue? {
        received += 1
        guard received <= MCPHTTPTransport.maximumResponseBytes else { throw MCPError.responseTooLarge }
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            return try finishLine()
        }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> JSONValue? {
        if firstLine {
            firstLine = false
            if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard hasData else { return nil }
            defer { eventData.removeAll(keepingCapacity: true); hasData = false }
            return try MCPRPCResponse.result(eventData, expectedID: expectedID, allowNotification: true)
        }
        if line.starts(with: [100, 97, 116, 97, 58]) { // data:
            var content = line.dropFirst(5)
            if content.first == 32 { content = content.dropFirst() }
            if hasData { eventData.append(10) }
            eventData.append(contentsOf: content)
            hasData = true
        } else if line == Data("data".utf8) {
            if hasData { eventData.append(10) }
            hasData = true
        }
        // Comments, event/id/retry fields and notifications are not logged or executed.
        return nil
    }
}

enum MCPRPCResponse {
    static func result(_ data: Data, expectedID: String, allowNotification: Bool = false) throws -> JSONValue? {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw MCPError.invalidResponse }
        guard case .object(let object) = value, object["jsonrpc"] == .string("2.0") else {
            throw MCPError.invalidResponse
        }
        if object["method"] != nil {
            guard object["method"]?.stringValue != nil, object["result"] == nil, object["error"] == nil else {
                throw MCPError.invalidResponse
            }
            if object["id"] != nil { throw MCPError.unsupportedServerRequest }
            guard allowNotification else { throw MCPError.invalidResponse }
            return nil
        }
        guard object["id"] == .string(expectedID) else { throw MCPError.responseIDMismatch }
        guard (object["result"] != nil) != (object["error"] != nil) else { throw MCPError.invalidResponse }
        if let error = object["error"] {
            guard case .number(let code)? = error["code"],
                  let number = Int(NSDecimalNumber(decimal: code).stringValue) else {
                throw MCPError.invalidResponse
            }
            throw MCPError.rpcFailure(rpcCode: number)
        }
        return object["result"]
    }
}
