import Foundation

enum MemorySafety {
    static func normalized(_ text: String) -> String { text.precomposedStringWithCompatibilityMapping }
    static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func keywords(_ words: [String]) throws -> [String] {
        guard words.count <= 8 else { throw MemoryError.invalidKeywords }
        var result: [String] = []
        for word in words.map(clean) where !word.isEmpty {
            guard word.utf16.count <= 30 else { throw MemoryError.invalidKeywords }
            if !result.contains(word) { result.append(word) }
        }
        return result
    }

    static func validate(content: String, keywords: [String], source: MemorySource) throws {
        guard !content.isEmpty, content.utf16.count <= 200,
              !content.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MemoryError.invalidContent
        }
        _ = try self.keywords(keywords)
        guard ["manual", "user_said"].contains(source.type), source.at.timeIntervalSince1970.isFinite,
              (source.conversationID?.utf16.count ?? 0) <= 256,
              (source.quote?.utf16.count ?? 0) <= 1000 else { throw MemoryError.invalidState }
        if source.type == "user_said" {
            guard let quote = source.quote, normalized(quote).trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= 2 else {
                throw MemoryError.invalidState
            }
        }
        if ([content] + keywords + [source.quote].compactMap { $0 }).contains(where: sensitive) {
            throw MemoryError.sensitiveContent
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func captures(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let range = $0.range(at: group)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// Best-effort exclusion, not a claim of complete secret detection.
    static func sensitive(_ text: String) -> Bool {
        let value = normalized(text)
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
        let credentials = #"(?:\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[A-Z0-9]{16})\b|\bBearer\s+\S+|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#
        let labeledSecret = #"(?:密碼|密码|口令|驗證碼|验证码|校驗碼|校验码|安全碼|安全码|password|passcode|passwd|cvv|cvc|verification\s*code|security\s*code|api[ _-]?key|access[ _-]?token|client[ _-]?secret)[\s:：=,，]*(?:是|為|为|叫|is|was|are)?[\s:：=]*[A-Za-z0-9_./+\-]{4,}"#
        let reversedSecret = #"[A-Za-z0-9]{4,}\s*(?:就是|是|為|为)(?:我的|我|用戶的|用户的)?\s*(?:密碼|密码|口令|驗證碼|验证码|安全碼|安全码|password|passcode)"#
        if matches(credentials, value) || matches(labeledSecret, value) || matches(labeledSecret, compact)
            || matches(reversedSecret, compact) || matches(#"\b(?:pin|otp)\s*[:=：]?\s*[0-9]{4,}"#, value) { return true }
        // Capability URLs are credentials, even if their random secret has no familiar prefix.
        if matches(#"https?://[^\s]*(?:/webhook(?:/|\b)|[?&](?:key|token|secret|signature|api_key|access_token)=)"#, value)
            || matches(#"https?://[^\s/]+@"#, value) { return true }
        // Deliberately conservative around national identifiers; do not retain them.
        if matches(#"(?<![0-9])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])|\b[A-Z][12][0-9]{8}\b"#, value) { return true }
        for candidate in captures(#"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#, value) {
            let digits = candidate.compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { continue }
            let sum = digits.reversed().enumerated().reduce(0) { sum, element in
                let digit = element.offset % 2 == 1 ? element.element * 2 : element.element
                return sum + (digit > 9 ? digit - 9 : digit)
            }
            if sum % 10 == 0 { return true }
        }
        return false
    }

    static func oneOff(_ text: String) -> Bool {
        matches(#"這次|这次|這一次|这一次|今天先|僅這次|仅这次|\bthis\s+time\b|\bjust\s+today\b|\bfor\s+now\b"#, text)
    }

    static func forgetRequested(quote: String, fullMessages: [String]) -> Bool {
        let positive = #"忘掉|忘記|忘记|別記|别记|不要記|不要记|不用記|不用记|刪除|删除|刪掉|删掉|\b(?:forget|delete|remove)\b"#
        let negative = #"(?:不|別|别|無需|无需|不用|不必|不要|不能|不准|禁止|不想)\s*(?:要|用|再|去)?\s*(?:刪|删|忘)|\b(?:do\s+not|don't|don’t|dont|never|not\s+to)\s+(?:delete|forget|remove)\b"#
        return matches(positive, quote) && !fullMessages.contains { matches(negative, $0) }
    }

    static func deniesUpdate(_ messages: [String]) -> Bool {
        let pattern = #"(?:不|別|别|不要|不用|不必|不能|不准|禁止|無需|无需)\s*(?:再|去)?\s*(?:修改|更新|更正|改成|改為|改为|改掉)|\b(?:do\s+not|don't|don’t|never|not\s+to)\s+(?:update|change|edit|correct)\b"#
        return messages.contains { matches(pattern, $0) }
    }

    /// A quoted substring alone is insufficient: concrete values must also occur in
    /// the user's statements. This heuristic cannot prove arbitrary paraphrases.
    static func grounded(_ value: String, utterances: [String]) -> Bool {
        let sources = utterances.map { normalized($0).lowercased() }
        let text = normalized(value)
        let specifics = captures(#"[「『“"]([^「」『』“”"\n]+)[」』”"]"#, text, group: 1)
            + captures(#"[0-9]+|[A-Za-z][A-Za-z0-9._-]{2,}"#, text)
            + captures(#"\p{Han}{2}(?:小區|小区|大廈|大厦|廣場|广场|公寓|花園|花园|單元|单元|路|街|巷|弄|鎮|镇|村|號|号|樓|楼|棟|栋|室|區|区|縣|县|市|省|園|园|苑|城|道|里|灣|湾)"#, text)
        let grammar: Set<String> = ["the", "user", "users", "prefers", "likes", "dislikes", "lives", "has", "their", "they", "are", "and", "with", "without", "always", "wants", "uses"]
        return specifics.allSatisfy { specific in
            let needle = specific.lowercased()
            return grammar.contains(needle) || sources.contains { $0.contains(needle) }
        }
    }
}
