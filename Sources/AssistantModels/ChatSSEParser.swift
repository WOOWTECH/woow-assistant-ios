import Foundation

/// Incremental, strictly UTF-8 SSE decoding. Limits include ignored comments/fields.
struct ChatSSEParser {
    static let maximumResponseBytes = 4 * 1024 * 1024
    static let maximumEventBytes = 256 * 1024
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var totalBytes = 0
    private var eventBytes = 0
    private var skipLF = false
    private var firstLine = true
    private var errorEvent = false
    private var receivedText = false
    private var stopped = false
    private(set) var done = false

    mutating func append(_ byte: UInt8) throws -> String? {
        totalBytes += 1
        eventBytes += 1
        guard totalBytes <= Self.maximumResponseBytes, eventBytes <= Self.maximumEventBytes else {
            throw HTTPChatModelError.responseTooLarge
        }
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            skipLF = byte == 13
            return try finishLine()
        }
        line.append(byte)
        return nil
    }

    func finish() throws {
        // EOF never implicitly dispatches an unterminated SSE event.
        guard done else { throw HTTPChatModelError.incompleteResponse }
    }

    private mutating func finishLine() throws -> String? {
        guard var text = String(bytes: line, encoding: .utf8) else {
            throw HTTPChatModelError.invalidResponse
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer {
                dataLines.removeAll(keepingCapacity: true)
                eventBytes = 0
                errorEvent = false
            }
            guard !dataLines.isEmpty else { return nil }
            guard !errorEvent else { throw HTTPChatModelError.invalidResponse }
            return try dispatch(dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let split = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = split.count == 2 ? String(split[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch split[0] {
        case "data": dataLines.append(value)
        case "event": errorEvent = value == "error"
        default: break
        }
        return nil
    }

    private mutating func dispatch(_ data: String) throws -> String? {
        guard !done else { throw HTTPChatModelError.invalidResponse }
        if data == "[DONE]" {
            guard stopped, receivedText else { throw HTTPChatModelError.incompleteResponse }
            done = true
            return nil
        }
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: Data(data.utf8)) }
        catch { throw HTTPChatModelError.invalidResponse }
        if chunk.choices.isEmpty {
            guard chunk.usage != nil else { throw HTTPChatModelError.invalidResponse }
            return nil
        }
        guard chunk.choices.count == 1, let choice = chunk.choices.first,
              choice.index == 0, !stopped else { throw HTTPChatModelError.invalidResponse }
        if let reason = choice.finish_reason {
            guard reason == "stop" else { throw HTTPChatModelError.incompleteResponse }
            stopped = true
        }
        if let text = choice.delta.content, !text.isEmpty {
            receivedText = true
            return text
        }
        return nil
    }

    private struct Chunk: Decodable {
        let choices: [Choice]
        let usage: Usage?
    }
    private struct Usage: Decodable {}
    private struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }
    private struct Delta: Decodable { let content: String? }
}
