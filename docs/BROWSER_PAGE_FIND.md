# 手動頁內尋找

本批以 `bb5c9eb73a48536cd8699170f86ba4328cf69ce7` 為基底，僅在獨立 worktree 開發。瀏覽器工具列新增「頁內尋找」（`browser.find`），使用 WebKit 的 `UIFindInteraction`，不建立另一套 JavaScript 搜尋器，也不呼叫模型。輸入、結果數、上一筆／下一筆、清除文字與完成由系統面板處理；不提供取代文字功能。

## 原版行為與原生 API

Pinned Mika：`0c172724f3f0c96f7345262588072f6e95db1138`。

| 原版證據 | 此批對應 |
| --- | --- |
| `UserBrowser.kt:416–442` 的 startFind / setFindQuery / findNext / stopFind | `presentPageFind()` 開啟原生面板；WebKit 處理查詢與雙向定位；原生完成鍵或 `closePageFind()` 關閉 |
| `UserBrowser.kt:593–603` 只接收目前分頁的結果 | 每個 BrowserSession 使用自己 WKWebView 的原生 find session；沒有 App 共用結果陣列 |
| load / newTab / selectTab / closeTab 的 stopFind | 導覽前及有效 provisional callback 清除；workspace 現有 suspension / cancel 接點、View 隱藏及 detach 撤銷 |
| `BrowserScreen.kt:168,219` 的關閉與前後結果控制 | 系統面板的完成、前後定位；原生鍵盤快捷鍵僅在可用的手動頁啟用 |

原版 `setFindQuery` 會 trim 字串；此批採用 UIKit 的原生文字比對、空白與搜尋選項語義，沒有宣稱逐字相同的 Android UI 行為。工具列重新開啟時明確給空查詢；App 不保存查詢。原生完成鍵的面板行為由 UIKit 負責；導覽／換頁時會直接移除 interaction 與舊 session。

Apple primary sources：

- [WKWebView.findInteraction](https://developer.apple.com/documentation/webkit/wkwebview/findinteraction)：iOS 16 起提供，本 App 最低 iOS 17。
- [UIFindInteraction](https://developer.apple.com/documentation/uikit/uifindinteraction)：原生文字欄位、前後結果控制與鍵盤快捷鍵。
- [presentFindNavigator(showingReplace:)](https://developer.apple.com/documentation/uikit/uifindinteraction/presentfindnavigator(showingreplace:))：本批固定 `false`。
- [searchText](https://developer.apple.com/documentation/uikit/uifindinteraction/searchtext)：設定面板初始查詢；本批不藉它注入模型或執行腳本。
- [UIFindSession](https://developer.apple.com/documentation/uikit/uifindsession)：hosted tests 透過公開 API 驗證實際結果數與高亮索引。
- [WebKit WKWebView 實作](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm)：公開 `isFindInteractionEnabled` 的停用會移除 interaction。產品不呼叫其私有 API，也不替換 WebKit find delegate。

## 授權與生命週期

- 僅目前可呈現、載入完成且仍允許手動瀏覽的頁面可用。登入回呼／query 類型的手動頁不必先成為研究 observation。
- automation 接管、研究／操作進行中、原生網站對話框、覆蓋面板、背景／離頁、換分頁、清除資料及退休 session 均不能開啟。停用 interaction 同時關閉硬體鍵盤入口。
- automation 結束或取消不會釋放既有文件所有權；仍須原本明確的手動導覽 commit。
- 新導覽先清除 find，回呼僅接受目前 navigation identity；已失效文件不可保留搜尋結果。Back／Forward／Reload 沿用現有 `manualNavigation` 接點。
- 查詢不加入模型上下文、URL、history、LearningStore 或設定；不新增網路／filesystem／腳本能力。既有網站本身的網路行為及 WebKit 系統行為不宣稱完全沒有 I/O。

## 驗證與整合

本機命令：`python3 scripts/check_browser_page_find_app.py`。它複製實際 App/module sources，以臨時加密 workspace、真實 macOS WebKit 執行查詢、導覽、分頁、automation 與清除資料檢查；另外執行既有 site-mode App regression 與 gated loopback HTTP regression。所有本機結果和來源 hash 由 report 記錄。

新增 hosted 類別 `BrowserPageFindIntegrationTests`，共三個方法：

1. `testNativeQueryNextPreviousCloseAndNavigation`
2. `testAutomationOwnershipAndRetiredDocument`
3. `testTabSelectionBackgroundAndCloseRevokeNativeFind`

它們直接執行 `BrowserPageFindAppChecks` 同一份行為 body；iOS 分支必須建立真實 `UIFindInteraction`，驗證 3／2／0 個實際結果、前後高亮索引及撤銷，不以 skip 取代失敗。檔案放在既有 `Tests/AssistantBrowserIntegrationTests`，重用已註冊的 `CheckBrowserSiteModesApp` Host／Probe；不需新增 target 或更改 project.yml。

既有 `BrowserWorkspaceUITests` 新增兩個方法，仍由現有 workspace／ui-workspace scopes 收錄：

- `testNativePageFindQueryNextPreviousAndClose`：實際輸入、前後按鈕導致真實頁面捲動、完成、無結果查詢。
- `testNativePageFindClearsOnReloadAndTabSwitch`：原生面板開啟時切換分頁及重新整理，確認舊查詢不恢復。

UI 測試只對新增兩案固定系統面板為英文，以有限語意標籤選取原生按鈕；不改其他案例語言，不注入查詢或略過找不到的控制項。首次 native run 仍須確認實際 UIKit AX、SE 幾何與系統面板動作；失敗時保留現有 AX／截圖附件。

本機 macOS 13 CLT 沒有 iOS SDK：Debug／Release App logic 可編譯並執行；UIKit／SwiftUI／XCTest 分支只有 iOS 17 syntax parse（warnings-as-errors），不等同 iOS typecheck、原生面板或 UI PASS。既有 macOS SDK 的 WebKit delegate isolation／async 建議警告保持可見，未修改產品以壓掉警告。native CI 由 parent 整合後執行，此批不 commit、push 或 dispatch。

## 此次本機結果

最終同版本 source snapshot 的 105 個來源 hash 全數一致，詳見 [安全報告](evidence/browser-page-find-local.json)。

| 實測項目 | Debug | Release |
| --- | ---: | ---: |
| 新頁內尋找：真實 WebKit／隔離加密 workspace（3 組） | 50 | 50 |
| 新 HTTP Back／Forward／Reload（1 組） | 26 | 不含 Debug fixture |
| 既有 site-mode／workspace 回歸 | 118 | 118 |
| 既有 HTTP GET／POST／cookie 回歸 | 12 | 不含 Debug fixture |

共 374 次 assertion executions；不是 374 個 XCTest methods。3 個新增 hosted methods、2 個新增 UI cases 尚未在 iOS 執行，不以本機結果替代原生驗收。
