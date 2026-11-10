import Foundation

public enum SkillExecutionDependencyStatus: String, Sendable {
    case implementedInRuntime, hostIntegrationRequired, unavailable, excluded
}

public struct SkillExecutionDependency: Equatable, Sendable {
    public let original: String
    public let status: SkillExecutionDependencyStatus
    public let mapping: String
}

public struct SkillExecutionDependencyReport: Sendable {
    public let skillID: String
    public let provenance: [SkillExecutionProvenance]
    public let dependencies: [SkillExecutionDependency]
    public var originalParity: Bool { false }
}

/// Reviewed against all six SKILL.md files and all three supporting assets at
/// 0c172724. These reports describe integration boundaries, never grant authority.
public enum SkillExecutionDependencies {
    public static func reports(catalog: BundledSkillCatalog) -> [SkillExecutionDependencyReport] {
        catalog.entries.map { entry in
            SkillExecutionDependencyReport(skillID: entry.id,
                provenance: ([entry.original] + entry.assets).map(SkillExecutionProvenance.init),
                dependencies: dependencies(for: entry.id))
        }
    }

    private static func dependencies(for id: String) -> [SkillExecutionDependency] {
        func row(_ source: String, _ status: SkillExecutionDependencyStatus, _ mapping: String) -> SkillExecutionDependency {
            SkillExecutionDependency(original: source, status: status, mapping: mapping)
        }
        let browser = row("web_navigate / web_read_page", .hostIntegrationRequired,
            "現有 BrowserSession.inspect/openLink 與 WebResearchRunner 可讀公開頁面、同來源連結；尚未接入此執行器，不能讀取其他 App。")
        switch id {
        case "configure-mika": return [
            row("settings_list / settings_set", .unavailable, "本 App 沒有可供技能呼叫的同等設定工具；模型、金鑰、登入、刪資料與容器網路均不可由技能修改。")]
        case "content-transcribe": return [browser,
            row("read_file /workspace/inbox", .unavailable, "此增量只接受使用者選取的 PDF；尚未實作字幕或文字檔讀取。"),
            row("references/transcript-output-formats.md", .hostIntegrationRequired, "完整原文已固定封存並驗證雜湊；格式指引不產生執行權限。"),
            row("語音辨識", .unavailable, "原版也沒有本機語音轉文字；只有音訊時需要文字稿。")]
        case "documents": return [browser,
            row("/workspace/inbox /workspace/downloads / web_downloads", .implementedInRuntime,
                "選取單一 PDF 的檔案選擇器取代工作區路徑；不掃描下載或資料夾。"),
            row("run_bundled_script: skills/documents/scripts/extract_pdf.py", .implementedInRuntime,
                "預設以原生 PDFKit 取文、選頁、資訊與密碼解鎖；原始腳本僅由另行設定且核准上傳的 worker 執行。"),
            row("scripts/manifest.json: apk:py3-pypdf; Python argparse/json/logging/os/sys", .hostIntegrationRequired,
                "iOS 不執行 Python。可選 worker 需要 Python 與 pypdf；原版未固定 pypdf 版本。"),
            row("--out / share_file", .hostIntegrationRequired, "App 可讓使用者選擇位置儲存擷取文字；尚未提供可由技能呼叫的分享工具。"),
            row("read_file / search_files", .unavailable, "尚未提供輸出文字的分段讀取或搜尋工具；不開放一般檔案系統存取。"),
            row("run_command + pypdf 拆分／合併／抽頁", .excluded, "不執行任意 Shell 或 Python；未提供 PDF 編輯或 OCR。")]
        case "info-research": return [browser,
            row("跨來源搜尋與兩個獨立原始來源", .hostIntegrationRequired, "瀏覽器受來源與導航政策限制；需要上層逐站授權並保留實際閱讀證據。"),
            row("Android App 站內搜尋", .excluded, "手機與其他原生 App 自動化不在範圍。")]
        case "messaging": return [
            row("聊天／收件匣讀取、收件人核對、發送後驗證", .hostIntegrationRequired,
                "現有 MCP 探索、選取工具與單次核准可作為接點；須實際找到該帳號的工具，不假設存在訊息服務。此執行器尚未接入。"),
            row("WeChat / Feishu / Instagram 原生 App 操作", .excluded, "不操作其他 App；原文『不用先問』不授予發送權限。")]
        case "skill-authoring": return [
            row("skill_search / skill_read", .hostIntegrationRequired, "App 的手動技能寫作可搜尋個人與原始技能、讀取全文；尚未由模型自主呼叫。"),
            row("ask_user / skill_save(markdown, quote, version)", .hostIntegrationRequired,
                "手動技能寫作會綁定本次要求，核對完整內容並核准後才儲存；版本衝突與取消會阻擋儲存，模型不能自行核准。")]
        default: return []
        }
    }
}
