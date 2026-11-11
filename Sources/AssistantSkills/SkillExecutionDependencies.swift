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
    public static let pdfQueryScope = "僅在獨立 PDF 查詢流程，確認模型目的服務後，讀取或逐字搜尋本次已擷取 PDF 的文字快照；引文需對應實際讀取。不開放任意路徑、workspace 或無上限讀取。"
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
            row("settings_list / settings_set", .implementedInRuntime, "在外觀頁開啟模型權限後，可列出並修改本 App 的跟隨系統／淺色／深色；會讀回實際設定。模型、金鑰、登入、刪資料與容器網路不提供給此工具。")]
        case "content-transcribe": return [
            row("web_read_page", .implementedInRuntime, "瀏覽器可擷取使用者核准之目前頁面文字；64 KiB 上限，不截斷全文，不讀表單或隱藏文字，來源網址隨快照保留。"),
            row("read_file /workspace/inbox", .implementedInRuntime, "原生選檔後逐檔核准讀取 UTF-8 文字或字幕，再確認模型目的服務。模型分段重疊讀取記憶體快照；不開放任意檔案路徑。"),
            row("references/transcript-output-formats.md", .implementedInRuntime, "將固定版本原文與完整格式參考送入模型；支援摘要、章節、文章、逐字稿及引文，需讀完全部位元組並逐字驗證每段引文才能完成。"),
            row("語音辨識", .unavailable, "原版也沒有本機語音轉文字；只有音訊時需要文字稿。")]
        case "documents": return [browser,
            row("/workspace/inbox /workspace/downloads / web_downloads", .implementedInRuntime,
                "由系統選檔器，或使用者明確點選此 App 的已完成下載取得單一 PDF；仍須逐步核准讀取與擷取。頁面處理限三檔，不掃描下載或資料夾。"),
            row("run_bundled_script: skills/documents/scripts/extract_pdf.py", .implementedInRuntime,
                "預設以原生 PDFKit 取文、選頁、資訊與密碼解鎖；原始腳本僅由另行設定且核准上傳的 worker 執行。"),
            row("scripts/manifest.json: apk:py3-pypdf; Python argparse/json/logging/os/sys", .hostIntegrationRequired,
                "iOS 不執行 Python。可選 worker 需要 Python 與 pypdf；原版未固定 pypdf 版本。"),
            row("--out / share_file", .hostIntegrationRequired, "App 可讓使用者選擇位置儲存擷取文字或組裝 PDF；尚未提供可由技能呼叫的分享工具。"),
            row("read_file / search_files", .implementedInRuntime, pdfQueryScope),
            row("PDF 抽頁／重排／合併", .implementedInRuntime, "可核准讀取一至三個靜態 PDF，再核對頁序產生新文件；合計輸入與輸出各限 200 頁，不支援加密、表單、註記、書籤、標記結構、圖層或互動文件。這是 PDFKit 實作，並非原版 Python。"),
            row("run_command + pypdf / OCR", .excluded, "iOS 不執行任意 Shell 或 Python；尚未提供 OCR 或通用遠端命令環境。")]
        case "info-research": return [browser,
            row("跨來源搜尋與兩個獨立原始來源", .hostIntegrationRequired, "瀏覽器受來源與導航政策限制；需要上層逐站授權並保留實際閱讀證據。"),
            row("Android App 站內搜尋", .excluded, "手機與其他原生 App 自動化不在範圍。")]
        case "messaging": return [
            row("聊天／收件匣讀取、收件人核對、發送後驗證", .hostIntegrationRequired,
                "現有 MCP 探索、選取工具與單次核准可作為接點；須實際找到該帳號的工具，不假設存在訊息服務。此執行器尚未接入。"),
            row("WeChat / Feishu / Instagram 原生 App 操作", .excluded, "不操作其他 App；原文『不用先問』不授予發送權限。")]
        case "skill-authoring": return [
            row("skill_search / skill_read", .implementedInRuntime, "模型協作編寫可實際搜尋個人與內建技能、讀取固定版本原文與附件，再提出草稿。"),
            row("ask_user / skill_save(markdown, quote, version)", .implementedInRuntime,
                "模型可詢問補充並準備草稿；綁定本次要求、原文與既有版本，使用者核對全文並核准後才儲存。取消、版本衝突或儲存失敗不會回報成功。")]
        default: return []
        }
    }
}
