import Foundation

public enum RawCommandEnvelopeError: Error, Equatable, Sendable { case invalidEnvelope }

/// Extract exact JSON value slices from one object. Decoded top-level duplicate
/// keys (including escaped spellings) are rejected. Nested values are preserved,
/// not re-encoded: each tool's own argument parser must reject duplicate argument
/// keys and enforce its schema before preparing any action. Callers bound bytes.
public enum RawCommandEnvelope {
    public static func fields(in text: String) throws -> [String: String] {
        do {
            var parser = Parser(text)
            let fields = try parser.fields()
            guard (try JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] else {
                throw RawCommandEnvelopeError.invalidEnvelope
            }
            return fields
        } catch { throw RawCommandEnvelopeError.invalidEnvelope }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        init(_ text: String) { bytes = Array(text.utf8) }
        mutating func fields() throws -> [String: String] {
            guard take(123) else { throw RawCommandEnvelopeError.invalidEnvelope }
            var result: [String: String] = [:]
            if !take(125) {
                while true {
                    let rawKey = try value()
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(rawKey.utf8)),
                          result[key] == nil, take(58) else { throw RawCommandEnvelopeError.invalidEnvelope }
                    result[key] = try value()
                    if take(125) { break }
                    guard take(44) else { throw RawCommandEnvelopeError.invalidEnvelope }
                }
            }
            space()
            guard offset == bytes.count else { throw RawCommandEnvelopeError.invalidEnvelope }
            return result
        }
        mutating func value() throws -> String {
            space()
            let start = offset
            var depth = 0, quoted = false, escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                if !quoted && depth == 0 && (byte == 44 || byte == 58 || byte == 125) { break }
                offset += 1
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 { depth += 1 }
                else if byte == 125 || byte == 93 { depth -= 1 }
            }
            guard start < offset, !quoted, depth == 0 else { throw RawCommandEnvelopeError.invalidEnvelope }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
        mutating func space() {
            while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            space()
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1; return true
        }
    }
}
