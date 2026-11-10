#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import CoreFoundation
import Foundation

enum TranscriptCommand {
    struct Citation { let readOffset: Int; let quote: String; let timestamp: String? }
    struct Section { let title: String; let text: String; let citations: [Citation] }
    case read(offset: Int, limit: Int)
    case finish(title: String, sections: [Section])
    case refuse(String)

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 48 * 1024 else { throw TranscriptCommandFailureReason.size }
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            throw TranscriptCommandFailureReason.syntax
        }
        guard let object = decoded as? [String: Any] else { throw TranscriptCommandFailureReason.fields }
        guard let action = object["action"] as? String else { throw TranscriptCommandFailureReason.action }
        switch action {
        case "tool":
            try keys(object, ["action", "name", "arguments"])
            guard object["name"] as? String == "read_file" else { throw TranscriptCommandFailureReason.tool }
            guard let args = object["arguments"] as? [String: Any] else { throw TranscriptCommandFailureReason.arguments }
            try keys(args, ["offset", "limit"], reason: .arguments)
            return .read(offset: try integer(args, "offset"), limit: try integer(args, "limit"))
        case "refuse":
            try keys(object, ["action", "reason"])
            return .refuse(try string(object, "reason", max: 1000))
        case "finish":
            try keys(object, ["action", "title", "sections"])
            guard let rows = object["sections"] as? [[String: Any]], (1...40).contains(rows.count) else {
                throw TranscriptCommandFailureReason.fields
            }
            let sections = try rows.map { row -> Section in
                try keys(row, ["title", "text", "evidence"])
                guard let items = row["evidence"] as? [[String: Any]], (1...20).contains(items.count) else {
                    throw TranscriptError.invalidEvidence
                }
                let evidence = try items.map { item -> Citation in
                    try keys(item, ["read_offset", "quote"], optional: ["timestamp"])
                    return Citation(readOffset: try integer(item, "read_offset"),
                        quote: try string(item, "quote", max: 8192),
                        timestamp: item["timestamp"] == nil ? nil : try string(item, "timestamp", max: 32))
                }
                return Section(title: try string(row, "title", max: 200), text: try string(row, "text", max: 16000), citations: evidence)
            }
            return .finish(title: try string(object, "title", max: 200), sections: sections)
        default: throw TranscriptCommandFailureReason.action
        }
    }

    private static func keys(_ object: [String: Any], _ required: Set<String>, optional: Set<String> = [],
                             reason: TranscriptCommandFailureReason = .fields) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw reason }
    }
    private static func string(_ object: [String: Any], _ key: String, max: Int) throws -> String {
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= max else { throw TranscriptCommandFailureReason.fields }
        return value
    }
    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= Double(Int32.max),
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { throw TranscriptError.invalidRange }
        return value.intValue
    }
}
#endif
