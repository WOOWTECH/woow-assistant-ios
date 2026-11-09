import Foundation
import CryptoKit

/// Additional safeguards for *automatic* learning. Imported text keeps its
/// existing validation rules. Heuristic injection detection is not a complete
/// prompt-injection defense: no calls execute, success needs grounded citations,
/// and all generated content must remain pending for user review.
enum SkillLearningSafety {
    struct JudgeMaskedText {
        let text: String
        /// Only unchanged source spans. Never export aliases as grounded quotations.
        let citationSegments: [String]
    }

    /// Request-local, injective URL identities. Keys use exact UTF-8 bytes, not
    /// Swift String's canonical-equivalence comparison or URL normalization.
    /// The random namespace prevents predictable aliases from being planted in
    /// page text; reserved markers in input are rejected before any model call.
    struct JudgeURLAliases {
        static let marker = "⟦WOOW_URL_"
        private let prefix = Self.marker + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "_"
        private var byURL: [Data: String] = [:]
        private var issued: Set<String> = []

        init?(inputs: [String]) {
            guard !inputs.contains(where: { $0.contains(Self.marker) }) else { return nil }
        }

        mutating func mask(_ text: String) -> JudgeMaskedText {
            var result = "", segments: [String] = []
            var cursor = text.startIndex
            for range in Self.urlRanges(text) {
                let unchanged = String(text[cursor..<range.lowerBound])
                result += unchanged; segments.append(unchanged)
                result += identity(forExactURL: String(text[range])); cursor = range.upperBound
            }
            let tail = String(text[cursor...]); result += tail; segments.append(tail)
            return JudgeMaskedText(text: result, citationSegments: segments)
        }

        /// A typed executor URL has no prose delimiters. Preserve every UTF-8 byte,
        /// including terminal punctuation, using the same map as extracted URLs.
        mutating func identity(forExactURL value: String) -> String {
            let bytes = Data(value.utf8)
            if let existing = byURL[bytes] { return existing }
            let alias = prefix + String(byURL.count + 1) + "⟧"
            byURL[bytes] = alias; issued.insert(alias)
            return alias
        }

        /// A response may discuss an issued alias, but cannot invent a URL identity.
        func containsOnlyIssuedAliases(_ text: String) -> Bool {
            var remaining = text[...]
            while let marker = remaining.range(of: Self.marker) {
                guard let end = remaining[marker.upperBound...].firstIndex(of: "⟧") else { return false }
                let after = remaining.index(after: end)
                guard issued.contains(String(remaining[marker.lowerBound..<after])) else { return false }
                remaining = remaining[after...]
            }
            return true
        }

        private static func urlRanges(_ text: String) -> [Range<String.Index>] {
            // Preserve quote/Markdown delimiters outside the URL. An explicitly
            // quoted URL keeps its literal final punctuation. For bare prose URLs,
            // leave trailing sentence punctuation and unmatched brackets unchanged.
            let regex = try! NSRegularExpression(pattern: #"https?://[^\s<>\"'`“”‘’「」『』]+"#, options: .caseInsensitive)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let explicitlyQuoted = before.map { "\"'`<“‘「『".contains($0) } ?? false
                var end = range.upperBound
                if !explicitlyQuoted {
                    var candidate = String(text[range])
                    while let last = candidate.last {
                        let isPunctuation = ".,;:!?，。；：！？、".contains(last)
                        let opening: Character? = last == ")" ? "(" : last == "]" ? "[" : last == "}" ? "{" : nil
                        let unmatched = opening.map { open in
                            candidate.filter { $0 == last }.count > candidate.filter { $0 == open }.count
                        } ?? false
                        guard isPunctuation || unmatched else { break }
                        candidate.removeLast(); end = text.index(before: end)
                    }
                }
                return range.lowerBound..<end
            }
        }
    }

    static func unsafe(_ text: String, apiKey: String) -> Bool {
        if !apiKey.isEmpty && text.contains(apiKey) { return true }
        if SkillSensitiveContent.containsSensitiveValue(text) { return true }
        let normalized = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[\\s\\p{Cf}]+", with: " ", options: .regularExpression)
        let patterns = [
            "(?i)(?:ignore|disregard|override|forget).{0,60}(?:previous|prior|system|developer|above|all).{0,30}(?:instructions?|prompts?|rules?)",
            "(?i)(?:system|developer)\\s*(?:message|prompt|instructions?)\\s*[:：]",
            "(?i)(?:reveal|exfiltrate|send|print).{0,40}(?:secrets?|api.?keys?|passwords?|system prompt)",
            "(?i)(?:return|output|judge|classify|mark).{0,30}(?:outcome.{0,12}done|always.{0,12}(?:success|done))",
            "(?:忽略|無視|无视|覆蓋|覆盖).{0,30}(?:指令|指示|規則|规则|提示)",
            "(?:系統|系统|開發者|开发者).{0,12}(?:指令|提示|訊息|消息)\\s*[:：]",
            "(?:判定|輸出|输出|回傳|返回).{0,20}(?:outcome|done|一律成功)",
            "(?i)<\\|(?:im_start|im_end|system|developer)\\|>|</?\\s*(?:system|developer)\\s*>"
        ]
        if patterns.contains(where: { SkillDocument.matches($0, normalized) }) { return true }
        // Credential-bearing URL user-info is unsafe even without a password keyword.
        return SkillDocument.captures("https?://[^\\s<>\"']+", normalized).contains { raw in
            guard let url = URLComponents(string: raw) else { return true }
            return url.user != nil || url.password != nil
        }
    }

    /// Never send full URLs (including secret webhook paths/query strings) into a
    /// secondary model call. Keep the host as source context only, like Mika.
    static func withoutURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+", options: .caseInsensitive) else { return "" }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let raw = String(output[range])
            let host = URLComponents(string: raw)?.host ?? "website"
            output.replaceSubrange(range, with: "[website \(host)]")
        }
        return output
    }

    static func actionSignature(_ action: SkillExecutedAction) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let normalized = action.arguments.mapValues { SkillDocument.normalize($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let bytes = try encoder.encode(normalized)
        var data = Data(action.toolName.utf8); data.append(0); data.append(bytes)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func uniqueActionCount(_ actions: [SkillExecutedAction]) -> Int {
        var signatures: Set<String> = []
        for action in actions where action.succeeded && action.kind != .observation && !action.result.isEmpty {
            if let signature = try? actionSignature(action) { signatures.insert(signature) }
        }
        return signatures.count
    }

    /// No typed text, raw arguments or tool-result prose in the drafter's digest.
    /// Remove quoted task values and numeric literals from goal/answer as well.
    static func generalized(_ text: String, goal: String, actions: [SkillExecutedAction]) -> String {
        var result = withoutURLs(text)
        var literals = SkillDocument.captures("[\"'“「『]([^\"'”」』\\n]{2,200})[\"'”」』]", goal, group: 1)
        let privateArgumentNames: Set<String> = ["text", "value", "query", "input", "content", "path", "file", "filename"]
        for action in actions {
            for (key, value) in action.arguments where privateArgumentNames.contains(key.lowercased()) && !value.isEmpty {
                literals.append(value)
            }
        }
        for literal in literals.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: literal, with: "<task-value>")
        }
        result = result.replacingOccurrences(of: "[0-9]+(?:[.,][0-9]+)*", with: "<number>", options: .regularExpression)
        return result
    }
}
