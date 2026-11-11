# Manual address input and search engines

This bounded change follows Mika revision `0c172724f3f0c96f7345262588072f6e95db1138`, specifically `browser/AddressInput.kt`, `SearchEngine.kt` (`SearchEngineSpec`), `SearchEngineStore.kt`, `StartPageModel.kt`, `RecentPages.kt`, and the address display/editor in `UserBrowser.kt` and the browser UI. It does not claim complete browser parity.

## Mika behavior retained

- Bing is the initial engine, followed by Google, DuckDuckGo and Baidu. Built-ins cannot be edited or removed. Adding a custom engine selects it; removing the selected custom engine restores Bing. Re-adding the same ID is a no-op.
- Empty input does nothing. Words, phrases, Unicode text and email addresses become searches. ASCII/punycode domains without a scheme become HTTPS destinations. Explicit URL input goes through the existing destination policy; a rejected destination is not retried as a search.
- A custom engine has a name and one `%s` placeholder. Every inserted query is UTF-8 percent-encoded; only ASCII letters, digits and `-._~` remain unescaped. Spaces use `%20`, semantically equivalent to Mika's form-encoding `+`.
- Query recognition uses all built-in and saved custom engines, in that order. It matches the template's exact prefix/suffix and decodes once, including `+` as a space. A suffix must end the URL or precede `&`/`#`. It does not reorder query parameters or decode twice.
- Search history stores the actual result URL. Reopening it does not submit the query through the currently selected engine. The history display derives `搜尋：query` and the engine name; deleting an engine does not rewrite saved URLs. Bookmarks retain their titles and user renames.
- The address editor retains the actual URL, as Mika's editor does. A separate read-only label shows the recognized query and engine. Engine selection affects the next manual search, with no current-document navigation, POST replay, cookie reset or WebView replacement.

## Deliberate iOS policy differences

The existing `BrowserManualNavigationPolicy` and `BrowserPolicy` still determine destinations. Search engines require public HTTPS; HTTP (including Mika's bare-IP/localhost HTTP shortcut), loopback, private/local addresses, URL credentials and non-web schemes remain blocked. Credential-shaped input is rejected instead of sending it to a search service. This preserves the existing lexical URL policy; it does not add a DNS-resolution or server-side safety guarantee.

Templates accept a path placeholder or a query **value** placeholder, never an authority or parameter-name placeholder. Malformed escapes, control characters, fragments, known authentication/session query parameters and callback/OAuth paths are rejected. Fragment templates that Mika accepts are intentionally unsupported because the iOS encrypted library strips fragments. A path query cannot become a dot-segment traversal. Query text such as `&`, `/`, `#`, `%`, a URL or JavaScript-looking text is only encoded data under the fixed approved engine destination.

Bounds are 20 custom engines, 80 characters per name, 2,048 UTF-8 bytes per template/query, and the existing 8,192-byte final URL limit. Inputs are trimmed. Search suggestions and a separate search history UI are outside this change.

Mika stores search settings in plain JSON with fallback defaults. iOS instead adds `searchSettings` to the existing encrypted version-1 browser library. Only an absent field defaults to Bing; malformed, null, unknown-selection or duplicate-ID state fails closed. Existing tabs, selected tab, history, bookmarks and manual site modes survive migration. Settings publish only after a successful encrypted write. Clearing browsing history retains engines and bookmarks; the existing website-data clearing flow remains unchanged.

No model source-discovery policy, website research policy, allowed tool, approval requirement or automatic search capability is added. Manual query pages continue to be ineligible for the current read-only website-research flow. Release HTTP policy and existing DEBUG fixture gates are unchanged.

## Validation and native boundaries

`python3 -B scripts/check_browser_search_app.py` builds copied actual module and App sources, then exercises Debug and Release with real macOS WebKit. It uses an in-memory synthetic encryption key and a temporary vault. Outgoing Bing/Google actions are observed through the real navigation delegate and cancelled before network I/O; custom results use a controlled `loadSimulatedRequest` HTTPS document. The harness checks persistence/restart/migration, atomic failed writes, query restoration, manual/research separation and unchanged current-page fields/cookies when the engine changes. It also runs the existing site-mode App checks.

Hosted `BrowserSearchIntegrationTests/testManualSearchEncryptionAndRealWebKit` calls that shared harness without launch flags or skips. `BrowserSearchTests/testManualAddressEncodingEnginesAndLegacyLibrary` runs the pure checks. `BrowserSearchUITests/testCustomSearchQueryAndSettingsSurviveRelaunch` uses the existing DEBUG UI fixture to check engine selection, adding/deleting a custom engine, encoded manual search, history display and relaunch persistence. It is registered in the workspace UI inventory, legacy workspace selector and hosted iOS 17 fixture allowlist. No live search service is required.

The development host has macOS 13 Command Line Tools and no Xcode. iOS syntax parsing is not SwiftUI/UIKit typechecking or native XCTest/UI execution. Actual iOS XCTest/UI execution remains for parent CI after integration. The prior site-mode HTTP GET/POST proof remains separate; this search harness does not turn simulated HTTPS documents into an HTTP proof or a rendered-iOS-content-mode claim.

Local freeze validation: pure core 115 assertions; actual App/WebKit 147 assertions in each of Debug and Release, plus 118 existing site-mode regression assertions in each. Both runs observed two GET search actions and zero navigations for engine selection. The 88 release/registry Python tests, 92-case UI inventory, XcodeGen 2.44.1 project generation and actionlint 1.7.12 passed. The review manifest carries hashes of the exact files, reports and patch.


## 整合期間發現的分類缺陷

原候選會把缺少斜線的 `http:`／`https:` 開頭輸入退回搜尋，包括合成帳密與 token 測試字串。父端與獨立 review 使用實際 pure helper 重現，沒有發送請求。新增回歸先在舊實作失敗，再以相同測試確認修正；這兩種已知網址 scheme 的畸形輸入現在直接拒絕，`site:example` 等搜尋操作詞仍保留。既有合法公開 HTTPS 導覽維持原政策。詳見 [修正前後證據](evidence/manual-search-url-classification-regression.json)。

搜尋設定面板納入頁內尋找的覆蓋狀態；開啟設定會結束原生 find，關閉後不恢復舊查詢。UI 分片與 watchdog 同時保留串流、網站版型、頁內尋找和搜尋案例；本機 WebKit 結果不替代原生介面驗收。
