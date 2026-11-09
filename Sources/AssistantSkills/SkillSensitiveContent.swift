import Foundation

/// Defense-in-depth import hygiene, not a general PII/DLP guarantee. Based on
/// Mika SensitiveFilter's value checks; never logs or returns the matching text.
enum SkillSensitiveContent {
    static func containsSensitiveValue(_ raw: String) -> Bool {
        let text = raw.precomposedStringWithCompatibilityMapping
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        let keywords = "支付密码|密碼|密码|口令|验证码|驗證碼|校验码|校驗碼|动态码|動態碼|安全码|安全碼|安全问题|安全問題|(?<![A-Za-z])(?:password|passcode|passwd|cvv|cvc|verification code|security code|security question|one-time code)(?![A-Za-z])"
        let gap = "[\\s:：=,，是为為叫]{0,4}(?:(?:is|was|are)\\s+)?"
        let owner = "\\s*(?:就是|是|为|為)(?:我的|我|用户的|使用者的)?\\s*"
        let pin = "(?<![A-Za-z])(?:pin|otp)(?![A-Za-z])"
        let patterns = [
            "(?i)(?:\(keywords))\(gap)[A-Za-z0-9]{4,}",
            "(?i)(?<![A-Za-z0-9])[A-Za-z0-9]{4,}\(owner)(?:\(keywords))",
            "(?i)\(pin)\(gap)[0-9]{4,}",
            "(?i)(?<![A-Za-z0-9])[0-9]{4,}\(owner)\(pin)",
            "(?i)(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})",
            "(?i)(?:authorization\\s*:\\s*bearer\\s+\\S{8,}|(?:api[_ -]?key|access[_ -]?token|client[_ -]?secret)\\s*[:=]\\s*[\\\"']?[A-Za-z0-9_./+-]{8,})",
            "-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
        ]
        if patterns.contains(where: { SkillDocument.matches($0, text) || SkillDocument.matches($0, compact) }) { return true }
        // A capability URL is a credential even when it has no recognizable key
        // prefix. It must stay in the MCP Keychain, not in model-facing skill text.
        if SkillDocument.matches(#"(?i)https?://[^\s]*(?:/webhook(?:/|\b)|[?&](?:key|token|secret|signature|api_key|access_token)=)"#, text)
            || SkillDocument.matches(#"(?i)https?://[^\s/]+@"#, text)
            || SkillDocument.matches(#"(?i)\b[A-Z][12][0-9]{8}\b"#, text) { return true }
        for candidate in SkillDocument.captures("(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])", text) {
            let digits = candidate.compactMap(\.wholeNumberValue)
            let sum = digits.reversed().enumerated().reduce(0) { total, entry in
                let value = entry.offset % 2 == 0 ? entry.element : entry.element * 2
                return total + (value > 9 ? value - 9 : value)
            }
            if (13...19).contains(digits.count), sum % 10 == 0 { return true }
        }
        for candidate in SkillDocument.captures("(?<![0-9])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])", text) {
            if validIdentityNumber(candidate) { return true }
        }
        return false
    }

    private static func validIdentityNumber(_ value: String) -> Bool {
        let chars = Array(value.uppercased())
        guard chars.count == 18,
              let year = Int(String(chars[6..<10])), year >= 1900,
              let month = Int(String(chars[10..<12])), let day = Int(String(chars[12..<14])) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = (0..<17).reduce(0) { $0 + (chars[$1].wholeNumberValue ?? 0) * weights[$1] }
        return Array("10X98765432")[sum % 11] == chars[17]
    }
}
