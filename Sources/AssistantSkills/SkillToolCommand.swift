#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import Foundation

/// A strict, single-operation envelope carried by the existing chat-completions
/// client, like the MCP conversation runner. This is not provider function calling.
enum SkillToolCommand {
    case search(String)
    case read(name: String, file: String?)
    case save(markdown: String, quote: String, version: String?)
    case question(String)
    case finish(String)

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 32 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let action = object["action"] as? String else { throw SkillToolError.invalidCommand }
        if action == "ask_user" || action == "finish" {
            let key = action == "ask_user" ? "question" : "message"
            try keys(object, required: ["action", key])
            let value = try string(object, key, max: 4000)
            return action == "ask_user" ? .question(value) : .finish(value)
        }
        try keys(object, required: ["action", "name", "arguments"])
        guard action == "tool", let name = object["name"] as? String,
              let args = object["arguments"] as? [String: Any] else { throw SkillToolError.invalidCommand }
        switch name {
        case "skill_search":
            try keys(args, required: ["query"])
            return .search(try string(args, "query", max: 200))
        case "skill_read":
            try keys(args, required: ["name"], optional: ["file_path"])
            return .read(name: try string(args, "name", max: 200), file: try optional(args, "file_path", max: 500))
        case "skill_save":
            try keys(args, required: ["markdown", "quote"], optional: ["version"])
            return .save(markdown: try string(args, "markdown", max: 8000),
                         quote: try string(args, "quote", max: 4000), version: try optional(args, "version", max: 64))
        default: throw SkillToolError.invalidCommand
        }
    }

    var toolName: String? {
        switch self {
        case .search: return "skill_search"
        case .read: return "skill_read"
        case .save: return "skill_save"
        default: return nil
        }
    }

    private static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw SkillToolError.invalidCommand
        }
    }
    private static func string(_ object: [String: Any], _ key: String, max: Int) throws -> String {
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= max else { throw SkillToolError.invalidCommand }
        return value
    }
    private static func optional(_ object: [String: Any], _ key: String, max: Int) throws -> String? {
        object[key] == nil ? nil : try string(object, key, max: max)
    }
}
#endif
