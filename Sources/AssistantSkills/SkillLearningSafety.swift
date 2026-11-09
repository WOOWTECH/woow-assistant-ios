import Foundation
import CryptoKit

/// Additional safeguards for *automatic* learning. Imported text keeps its
/// existing validation rules. Heuristic injection detection is not a complete
/// prompt-injection defense: no calls execute, success needs grounded citations,
/// and all generated content must remain pending for user review.
enum SkillLearningSafety {
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
