# iOS 17 非 Live UI 分片

`release-ios.yml` 的 `ios17_test_scope` 現在提供下列互斥 UI 分片。每個分片以整個 XCTest 類別選取，核心測試另用 `core`。既有 `all`、`workspace`、`files`、`parity`、`startup`、`startup-smoke` 保留作相容或局部診斷用途；它們不是此分片集合的成員。

| Scope | 類別 | 目前 methods |
|---|---|---:|
| `ui-startup` | `WoowAssistantUITests`、`SelfConfigurationUITests` | 13 |
| `ui-notifications` | `NotificationUITests` | 1 |
| `ui-workspace` | `BrowserWorkspaceUITests`、`BrowserLoginUITests` | 5 |
| `ui-browser` | `BrowserInteractionUITests`、`BrowserUploadUITests` | 5 |
| `ui-learning` | `BrowserLearningUITests`、`MultiSourceResearchUITests` | 5 |
| `ui-memory` | `MemoryUITests`、`MemoryRaceUITests` | 8 |
| `ui-profile` | `UserProfileUITests`、`UserProfileToolUITests` | 9 |
| `ui-memory-tools` | `MemoryToolUITests` | 6 |
| `ui-skills` | `SkillCatalogUITests`、`SkillAuthoringUITests`、`TranscriptUITests` | 10 |
| `ui-documents` | `SkillExecutionUITests`、`SkillWorkerSettingsUITests` | 14 |
| `ui-mcp` | `MCPConversationUITests`、`MCPLearningUITests` | 8 |

合計 21 個類別、84 個非 Live methods；另有 22 個 Live methods 明確分開。這是目前來源清單，不是已執行或全面通過的數目。`ui-notifications` 使用真實系統權限與原生通知橫幅，模型仍為固定測資；宜用此次作業專用的新模擬器，不能以 App 偏好重設冒充系統權限重設。

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

workflow 的 `ios17_host_arch`、`startup-smoke` 與精確 runtime 比對保持不變。17.0.1 與 17.5 要分別跑 `core` 和全部 11 個 UI 分片，不能混用版本／架構補齊。清單檢查也在 native 工作開始前執行；任何新非 Live 類別必須加入唯一分片，新 methods 自動跟隨所屬類別。清單拒絕遺漏、重複、錯字、把 Live 放進分片、以及無法判讀的宣告。現有來源採一個同名 Swift 檔案對應一個 XCTestCase 類別；新增繼承測試或 extension methods 時須明確更新檢查器。

## 結果界線

每次 artifact 保存 `ui-test-inventory.json`（全部分片與 methods、排除的 Live 清單、清單 SHA-256）及 `report.json` 的 revision、實際 runtime、host architecture、scope 與預期 UI methods。未提供可信 `GITHUB_SHA` 的本機執行記為 null，不能假設與另一個 artifact 同版。

成功退出碼還必須配合實際 xcresult summary：總數與通過數相等且大於零，failed／skipped／expected failures 全為零。每個選取的 UI method 必須在實際 XCTest 日誌中恰好完成一次且 passed；只有 started、漏跑、非預期案例或重複嘗試都不會通過。純 UI scope 的 summary 總數還必須等於 inventory 預期數。未知摘要／日誌格式保留原始證據並失敗，不猜測成功。

`selected_tests_succeeded=true` 僅代表所選範圍完成；任何單一 UI 分片、`core` 或 `startup-smoke` 的 `runtime_tested`／`full_acceptance_succeeded` 都是 false。只有舊的 `all` 真正包含所有 Live、零略過，且通過完成清單檢查，才可能設定這兩個欄位。這比舊版僅檢查 xcodebuild 退出碼更嚴格：缺少 Live 條件造成 skip 的 `all` 現在會明確驗證失敗。

人工彙整時，必須核對同一 revision、精確 runtime／build、host architecture、inventory hash 的 `core` 與全部 11 片，各自沒有失敗／略過／遺漏，才可陳述「此版本與架構的全部非 Live 測試通過」。這不代表 Live、真機或完整產品驗收通過。單次 smoke 成功只證明那一個案例；此腳本不會自動把不同執行或不同版本合併成全面通過。

本機驗證使用真實來源檔案與合成 XCTest command／summary fixtures；不代表本機有執行 iOS 或 Xcode。現有原生 artifact、尚未完成的分片及原始失敗應繼續分開保留。
