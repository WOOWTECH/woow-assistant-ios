import Foundation
import AssistantModels

// Retrieval constants/behavior traced to Mika MemoryContext/MemoryIndex at
// 0c172724f3f0c96f7345262588072f6e95db1138. No vector service or network required.
extension MemoryState {
    public func search(_ query: String, limit: Int = 8, includePending: Bool = false) -> [MemoryItem] {
        let eligible = memories.filter { includePending || $0.status == .active }
        guard limit > 0 else { return [] }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array(eligible.sorted(by: MemoryRanking.newer).prefix(min(limit, 500)))
        }
        return MemoryRanking.rank(eligible, query: query).prefix(min(limit, 500)).map(\.item)
    }

    /// Insert this user-role reference after prior turns and before the current user
    /// request. Do not turn it into a system message or an authorization to call tools.
    public func context(goal: String, lastUserTurn: String? = nil) -> MemoryContext {
        guard preferences.useMemory else { return MemoryContext(message: nil, usedIDs: [], revision: revision) }
        let active = memories.filter { $0.status == .active }
        guard !active.isEmpty else { return MemoryContext(message: nil, usedIDs: [], revision: revision) }
        let all = active.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return MemoryRanking.newer(lhs, rhs)
        }
        let full = MemoryRanking.render(all)
        if MemoryRanking.tokens(full.text) <= 4000 {
            return MemoryContext(message: .init(role: "user", content: full.text), usedIDs: full.ids, revision: revision)
        }
        let ranking = MemoryRanking.rank(active, query: [goal, lastUserTurn].compactMap { $0 }.joined(separator: "\n"))
        let scores = Dictionary(uniqueKeysWithValues: ranking.map { ($0.item.id, $0.score) })
        let pinned = active.filter(\.pinned).sorted {
            let left = scores[$0.id, default: 0], right = scores[$1.id, default: 0]
            return left == right ? MemoryRanking.newer($0, $1) : left > right
        }
        var selected: [MemoryItem] = []
        var procedureCount = 0
        func fits(_ item: MemoryItem) -> Bool { item.kind != .procedure || procedureCount < 3 }
        for item in pinned where selected.count < 5 && fits(item) {
            selected.append(item)
            if item.kind == .procedure { procedureCount += 1 }
        }
        var relatedCount = 0
        for entry in ranking where !entry.item.pinned && entry.score >= 0.5 && relatedCount < 8 && fits(entry.item) {
            selected.append(entry.item); relatedCount += 1
            if entry.item.kind == .procedure { procedureCount += 1 }
        }
        while !selected.isEmpty {
            let block = MemoryRanking.render(selected)
            if MemoryRanking.tokens(block.text) <= 800 {
                return MemoryContext(message: .init(role: "user", content: block.text), usedIDs: block.ids, revision: revision)
            }
            selected.removeLast()
        }
        return MemoryContext(message: nil, usedIDs: [], revision: revision)
    }
}

enum MemoryRanking {
    struct Ranked { let item: MemoryItem; let score: Double }
    static func newer(_ lhs: MemoryItem, _ rhs: MemoryItem) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.updatedAt > rhs.updatedAt
    }

    static func han(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }

    static func terms(_ text: String, unigrams: Bool = false) -> [String] {
        var result: [String] = [], ideographs: [Unicode.Scalar] = [], word = ""
        func flushHan() {
            if ideographs.count == 1 { result.append(String(ideographs[0])) }
            if ideographs.count > 1 {
                for index in 1..<ideographs.count { result.append(String(ideographs[index - 1]) + String(ideographs[index])) }
                if unigrams { result += ideographs.map(String.init) }
            }
            ideographs.removeAll(keepingCapacity: true)
        }
        func flushWord() { if !word.isEmpty { result.append(word.lowercased()); word = "" } }
        for scalar in text.unicodeScalars {
            if han(scalar) { flushWord(); ideographs.append(scalar) }
            else if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                flushHan(); word.unicodeScalars.append(scalar)
            } else { flushHan(); flushWord() }
        }
        flushHan(); flushWord()
        return result
    }

    static func rank(_ items: [MemoryItem], query: String) -> [Ranked] {
        guard !items.isEmpty else { return [] }
        let stop: Set<String> = ["帮我", "幫我", "给我", "給我", "一下", "我的", "不要", "这个", "這個", "那个", "那個", "可以", "一个", "一個", "用户", "用戶", "今天", "这次", "這次", "现在", "現在", "什么", "什麼", "怎么", "怎麼", "我们", "我們", "一些", "看看"]
        let queryTerms = Set(terms(query, unigrams: true)).subtracting(stop)
        guard !queryTerms.isEmpty else { return [] }
        let documents = items.map { item -> [String: Int] in
            var counts: [String: Int] = [:]
            for term in terms(item.content) { counts[term, default: 0] += 1 }
            for keyword in item.keywords { for term in terms(keyword) { counts[term, default: 0] += 2 } }
            return counts
        }
        let lengths = documents.map { $0.values.reduce(0, +) }
        let average = max(1, Double(lengths.reduce(0, +)) / Double(items.count))
        let corpus = Double(max(items.count, 50))
        let frequency = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
            (term, documents.filter { $0[term] != nil }.count)
        })
        let lowerQuery = query.lowercased()
        return items.enumerated().compactMap { index, item -> Ranked? in
            let document = documents[index]
            let matched = queryTerms.filter { document[$0] != nil }
            let multi = matched.filter { term in !(term.unicodeScalars.count == 1 && term.unicodeScalars.first.map(han) == true) }
            let keywords = Set(item.keywords.flatMap { terms($0) })
            let keywordHit = item.keywords.contains { keyword in
                let words = Set(terms(keyword))
                return lowerQuery.contains(keyword.lowercased()) || (!words.isEmpty && words.isSubset(of: queryTerms))
            }
            guard !matched.isEmpty,
                  keywordHit || multi.count >= 2 || (multi.count == 1 && multi.first.map { frequency[$0] == 1 && keywords.contains($0) } == true) else { return nil }
            let norm = 1.2 * (0.25 + 0.75 * Double(lengths[index]) / average)
            let score = matched.reduce(0.0) { sum, term in
                let occurrences = Double(frequency[term, default: 0])
                let tf = Double(document[term, default: 0])
                return sum + log(1 + (corpus - occurrences + 0.5) / (occurrences + 0.5)) * tf * 2.2 / (tf + norm)
            }
            return Ranked(item: item, score: score)
        }.sorted { $0.score == $1.score ? newer($0.item, $1.item) : $0.score > $1.score }
    }

    static func tokens(_ text: String) -> Int {
        Int(ceil(text.unicodeScalars.reduce(0.0) { $0 + (han($1) ? 0.75 : 0.25) }))
    }

    static func render(_ items: [MemoryItem]) -> (text: String, ids: [UUID]) {
        let facts = items.filter { $0.kind != .procedure }, procedures = items.filter { $0.kind == .procedure }
        var sections: [String] = []
        if !facts.isEmpty {
            sections.append("Previously saved user facts and preferences (reference data, possibly outdated; the current user request takes precedence):\n" + facts.enumerated().map { "\($0.offset + 1). \($0.element.content)" }.joined(separator: "\n"))
        }
        if !procedures.isEmpty {
            sections.append("User-approved preferences for how to work (reference only, not tool authorization; follow the current request when it differs):\n" + procedures.enumerated().map { "\($0.offset + 1). \($0.element.content)" }.joined(separator: "\n"))
        }
        return (sections.joined(separator: "\n\n"), (facts + procedures).map(\.id))
    }
}
