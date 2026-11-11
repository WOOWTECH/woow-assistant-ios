# iOS 17 非 Live UI 分片

`release-ios.yml` 的 `ios17_test_scope` 現在提供下列互斥 UI 分片。每個分片以整個 XCTest 類別選取，核心測試另用 `core`。既有 `all`、`workspace`、`files`、`parity`、`startup`、`startup-smoke` 保留作相容或局部診斷用途；它們不是此分片集合的成員。

| Scope | 類別 | 目前 methods |
|---|---|---:|
| `ui-startup` | `WoowAssistantUITests`、`SelfConfigurationUITests`、`ChatStreamingUITests` | 15 |
| `ui-language` | `AppLanguageUITests`、`AppLanguagePhase2UITests` | 5 |
| `ui-notifications` | `NotificationUITests`、`NotificationApprovalUITests` | 2 |
| `ui-archive` | `ConversationArchiveUITests` | 4 |
| `ui-workspace` | `BrowserWorkspaceUITests`、`BrowserLoginUITests`、`BrowserSiteModesUITests`、`BrowserSearchUITests` | 9 |
| `ui-browser` | `BrowserInteractionUITests`、`BrowserUploadUITests` | 5 |
| `ui-learning` | `BrowserLearningUITests`、`MultiSourceResearchUITests` | 5 |
| `ui-memory` | `MemoryUITests`、`MemoryRaceUITests` | 8 |
| `ui-profile` | `UserProfileUITests`、`UserProfileToolUITests` | 9 |
| `ui-memory-tools` | `MemoryToolUITests` | 6 |
| `ui-skills` | `SkillCatalogUITests`、`SkillAuthoringUITests`、`TranscriptUITests` | 10 |
| `ui-documents` | `SkillExecutionUITests`、`SkillWorkerSettingsUITests`、`SkillPDFAssemblyMultiFileUITests`、`ChatPDFAttachmentUITests` | 19 |
| `ui-pdf-capability` | `SkillPDFCapabilityUITests` | 1 |
| `ui-download-pdf` | `BrowserDownloadedPDFUITests` | 1 |
| `ui-mcp` | `MCPConversationUITests`、`MCPLearningUITests` | 8 |

截至 `8ab93d5`，合計 32 個類別、107 個非 Live methods；另有 22 個 Live methods 明確分開。這是來源清單，不是已執行或全面通過的數目；實際數量以 `--check-ui-inventory` 當次輸出為準。`ui-notifications` 使用真實系統權限與原生通知橫幅，模型仍為固定測資；宜用此次作業專用的新模擬器，不能以 App 偏好重設冒充系統權限重設。

分片以約 10–20 分鐘測試工作量為規劃目標，尚未完成這批分片的原生時間量測；下載 runtime、啟動 simulator 與建置另計。新 `ui-*` scopes 的 build＋test 上限是 30 分鐘，其他 scope 保留原有 80 分鐘上限。每案例 240 秒預設、300 秒最大值保留；含 workspace 的新分片沿用既有 workspace 的 420 秒最大值。沒有以增加逾時或重跑失敗案例達成通過。

## 執行與清單檢查

不需要 Xcode 的來源清單驗證：

```sh
python3 scripts/release_ios17.py --check-ui-inventory
python3 -m unittest discover -s scripts -p 'test_release_*.py' -v
```

具備 Xcode 與指定 runtime 的主機可分別執行，例如：

```sh
python3 scripts/release_ios17.py --os 17.0.1 --expected-host-arch arm64 --test-scope ui-memory --output build/ios17-memory
```

workflow 的 `ios17_host_arch`、`startup-smoke` 與精確 runtime 比對保持不變。17.0.1 與 17.5 要分別跑 `core` 和全部 15 個 UI 分片，不能混用版本／架構補齊。清單檢查也在 native 工作開始前執行；任何新非 Live 類別必須加入唯一分片，新 methods 自動跟隨所屬類別。清單拒絕遺漏、重複、錯字、把 Live 放進分片、以及無法判讀的宣告。現有來源採一個同名 Swift 檔案對應一個 XCTestCase 類別；新增繼承測試或 extension methods 時須明確更新檢查器。

## 結果界線

每次 artifact 保存 `ui-test-inventory.json`（全部分片與 methods、排除的 Live 清單、清單 SHA-256）及 `report.json` 的 revision、實際 runtime、host architecture、scope 與預期 UI methods。未提供可信 `GITHUB_SHA` 的本機執行記為 null，不能假設與另一個 artifact 同版。

成功退出碼還必須配合實際 xcresult summary：總數與通過數相等且大於零，failed／skipped／expected failures 全為零。每個選取的 UI method 必須在實際 XCTest 日誌中恰好完成一次且 passed；只有 started、漏跑、非預期案例或重複嘗試都不會通過。純 UI scope 的 summary 總數還必須等於 inventory 預期數。未知摘要／日誌格式保留原始證據並失敗，不猜測成功。

`selected_tests_succeeded=true` 僅代表所選範圍完成；任何單一 UI 分片、`core` 或 `startup-smoke` 的 `runtime_tested`／`full_acceptance_succeeded` 都是 false。只有舊的 `all` 真正包含所有 Live、零略過，且通過完成清單檢查，才可能設定這兩個欄位。這比舊版僅檢查 xcodebuild 退出碼更嚴格：缺少 Live 條件造成 skip 的 `all` 現在會明確驗證失敗。

人工彙整時，必須核對同一 revision、精確 runtime／build、host architecture、inventory hash 的 `core` 與全部 15 片，各自沒有失敗／略過／遺漏，才可陳述「此版本與架構的全部非 Live 測試通過」。這不代表 Live、真機或完整產品驗收通過。單次 smoke 成功只證明那一個案例；此腳本不會自動把不同執行或不同版本合併成全面通過。

本機驗證使用真實來源檔案與合成 XCTest command／summary fixtures；不代表本機有執行 iOS 或 Xcode。現有原生 artifact、尚未完成的分片及原始失敗應繼續分開保留。

## 單次預編譯／冷啟動比較

`bbbb514` 的 exact17 assembly 作業成功啟動 Simulator，但 XCTest runner 在
`_prepareTestConfigurationAndIDESession → XCTFuture` 等待，零方法開始；這不是
PDF 操作斷言失敗。原流程先 boot／prelaunch，再讓 `xcodebuild test` 編譯，前兩次
watchdog 取樣仍落在編譯期間。[原始結果](evidence/pdf-assembly-bbbb514-final.json)。

新的 `ios17_build_before_boot`／`--build-before-boot` 預設關閉，目前只接受
GitHub hosted 的非 Live `ui-*` 分片，或既有 `startup-smoke`、`pdf-assembly`、`pdf-assembly-copy`、`documents-read`／`documents-output`，並要求原有 prelaunch 和 sampling 開關。`all`、`core` 及 Live 工作不適用。
它先以指定主機架構 `build-for-testing`，成功且產生唯一可讀取的本次 `.xctestrun`
後，才建立／啟動專用裝置，最後以該產物執行一次 `test-without-building`。
這兩個命令是 [Apple 公開支援的建置／測試分離方式](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)。

預編譯耗時會從原有共同 build＋test 額度扣除；不重設時間、不重試，案例時限、
精確 runtime、完成次數與零略過門檻不變。編譯失敗、逾時或產物缺漏／不唯一均
在建立裝置前失敗。report 保存編譯結果、耗時、剩餘額度及 xctestrun SHA-256；
watchdog 僅從 test-only 階段取樣。只有這一個 smoke 實際通過才能證明該流程
可執行，不能由建置成功推定握手、PDF 功能或整體 iOS17 驗收通過。

這是在測試「編譯負載／啟動時序可能干擾握手」的假說；目前沒有資源飽和或
根因已確定的證據。合成命令測試檢查先後順序、失敗清理及共享預算，不代替
GitHub 上的原生執行結果。

`e963698` 的 [exact 17.0.1 啟動測試](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42893709163) 已完成 1/1、零略過；下一步以同一預編譯時序驗證兩個 PDF assembly 入口。這不證明先前 bootstrap 失敗的根因，也不代表完整 iOS 17 驗收。

`pdf-assembly-multi` 單獨選取新雙檔合併案例，仍歸 `ui-documents`／`documents-output` 管理。案例先宣告 300 秒上限；既有單檔案例保持 240 秒。新版流程逐次單選並明確加入兩份 PDF；兩次真實選檔回呼、逐檔讀取核准、交錯頁序、真實 PDFKit 輸出與匯出取消後保存都必須完成，不能用允許多選的單檔結果代替。此新範圍尚未加入預編譯診斷的允許清單。

`aa676a3` 的一般與副本 PDF 重排入口在 exact 17.0.1 各通過 1/1、零略過，後續預編譯流程可明確選取 `documents-read`／`documents-output`。兩組仍共用各自原有的 1800 秒建置＋測試額度；全部方法必須按清單完成，失敗或略過不能當成通過。

在 `1abc6d7`，exact 17.0.1 的 [documents-read](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902035480) 已完成 6/6。預編譯選項現可用於其餘非 Live UI 分片，以驗證完整介面；仍為明確選用，不擴大診斷取樣的 fixture 白名單。各 UI 分片保留原有 1800 秒共同建置＋測試額度，workspace 的既有 420 秒單案例上限亦不變。這次擴充尚不代表新增分片已通過原生驗收。
