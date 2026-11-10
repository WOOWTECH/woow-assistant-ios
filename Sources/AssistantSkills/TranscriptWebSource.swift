#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import Foundation

public enum TranscriptSourceKind: String, Sendable {
    case selectedFile = "user_selected_utf8_text_only"
    case approvedWebPage = "user_approved_web_page_text_only"
}

extension TranscriptSnapshot {
    /// Trusted host entry after the person explicitly approves the inspected
    /// page text. This validates data only; it cannot open/fetch a URL, inspect a
    /// web view, read a file, or grant the model navigation authority.
    public static func fromUserApprovedWebPage(title: String, text: String, url: URL) throws -> TranscriptSnapshot {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              url.absoluteString.utf8.count <= 4096,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 512,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TranscriptError.invalidSelection
        }
        return try TranscriptSnapshot(filename: title, data: Data(text.utf8), sourceKind: .approvedWebPage, sourceURL: url)
    }
}
#endif
