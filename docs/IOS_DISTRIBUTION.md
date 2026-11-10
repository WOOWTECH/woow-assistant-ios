# iOS 簽章與最低版本驗證

查核日期：2026-11-10。整合提交 `d160a24` 已通過 Release 裝置編譯；17.0.1／17.5 模擬器均已啟動並實際執行 App 與 XCTest，但驗收尚未全數通過。`1153d5a` 修正已重現的原始網址連接埠檢查，待 iOS 重測。目前尚無真機驗收、distribution 簽章成功或可安裝發行包。

## 已確認的環境與缺口

| 查核項目 | 本次實際結果 |
| --- | --- |
| 本機 | macOS 13.7.8、Intel、Swift 5.8.1、Command Line Tools；`xcrun --find xcodebuild` 退出 72，沒有完整 Xcode |
| 簽章身分 | `security find-identity -v -p codesigning`：0 valid identities；未匯出私鑰、未建立／撤銷憑證 |
| 描述檔 | session HOME 與 OS 帳號 HOME 的兩個標準 provisioning profile 目錄均無 `.mobileprovision` |
| 連接裝置 | 唯讀 USB inventory 未見 iPhone／iPad／iPod；沒有 Xcode device tooling 或 `idevice_id`，無法證明 Wi-Fi 配對裝置不存在；未輸出序號 |
| GitHub secrets 名稱 | 母任務已使用已驗證身分的 `gh` 僅查名稱：repository secrets 恰為 `WOOW_HA_MCP_TEST_URL`、`WOOW_MODEL_TEST_API_KEY`；下列五個 iOS 簽章 secrets 均不存在，未讀取或輸出 secret 值 |
| GitHub 自管 runner | 母任務查詢 repository runners API 回傳 `[]`；目前沒有 repository 自管 runner |
| 既有 CI | 基準 `ios.yml` 使用 iOS 18.5／26.2；設定 deployment target 17.0 不等於曾在 iOS 17 上執行 |

Apple 說明 Xcode 15.4 支援 macOS 14；Xcode 16.4 支援 macOS 15.3 起且包含 iOS 18.5 SDK，其 simulator 支援範圍包含 iOS 17。Xcode 15.2 可用於 macOS 13.5 起，所以本機缺少的是完整工具鏈，不能把 macOS 13 說成絕對無法測 iOS 17；本次不安裝 Xcode。[Apple 相容表](https://developer.apple.com/xcode/system-requirements/)

GitHub 的 `macos-13` 於 **2025-12-04** 退役；`macos-14`、`macos-14-large`、`macos-14-xlarge` 於 **2026-11-02** 退役。因此現在不能將 hosted macOS 14＋Xcode 15.4 當作可用解法。[macOS 13 公告](https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/)、[macOS 14 公告](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/)

目前官方仍列 `macos-15-intel`；`macos-15` 已是 arm64，不能用標籤名稱推斷為 Intel。本流程明確選用 Intel 映像；查閱時映像清單包含 Xcode 16.4／26.2，未預載 iOS 17。[runner 規格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[映像工具清單](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)

Apple 提供 `xcodebuild -downloadPlatform iOS -buildVersion <版本>` 安裝指定 runtime。首次 hosted 實跑已成功安裝 17.0.1（21A342），但模擬器啟動超過 300 秒；後續改為首次啟動限時 900 秒並保存日誌。下載仍限時 20 分鐘，保留退出碼／逾時狀態與前後 runtime inventory。[Apple 安裝說明](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

另已實際讀取 Apple 公開 runtime catalog，仍列 iOS 17.0（21A328，7,559,529,352 bytes）、17.0.1（21A342，7,210,691,623 bytes）、17.5（21F79，7,336,630,623 bytes），標示 `authentication: virtual`。對三個原始下載來源進行無認證 HEAD 均轉到 `developer.apple.com` 的 `text/html` 頁面；這不是 DMG 下載成功，也不能推論 Xcode installer 必須另登入。沒有下載大型映像或取得任何帳號認證；流程使用 Apple installer，不用 `curl` 把 HTML 當 runtime。[Apple runtime catalog](https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex)

## 已實作的流程

`.github/workflows/release-ios.yml` 只有手動 `workflow_dispatch`，`contents: read`，checkout 不保存認證。使用者已授權 push 與 CI；已提交整合版的 `unsigned-device` 與兩個精確版本的 `ios17-hosted`。沒有另設 environment 核准閘門。

| mode | 工具鏈 | 執行內容／產物 |
| --- | --- | --- |
| `unsigned-device`（預設） | `macos-15-intel`、Xcode 26.2 | Release `iphoneos` arm64 編譯；檢查實際 build settings、App Info.plist、App／framework／Swift dylib 的 Mach-O 最低版本；不產生 IPA |
| `signed-export` | 同上；repository Actions secrets | 既有 distribution 憑證與 profile 預檢、手動簽章 archive、`destination=export` 本地 IPA 匯出；驗證簽章完整性及實際 leaf certificate |
| `ios17-hosted` | `macos-15-intel`、Xcode 16.4 | 指定 runtime 若缺少便下載；建立專用 iPhone 15 simulator，執行現有 `WoowAssistant` 完整 XCTest scheme，保存 `.xcresult`／測試 log |
| `ios17-self-hosted` | `[self-hosted, macOS, woow-ios17]`，使用 runner 已選定的 Xcode | 僅用已預裝的指定 runtime；缺少即失敗，不自動改用其他 OS |

建置與測試在獨立產生的 `.xcodeproj` 進行，不修改 `project.yml`；Debug／Release plist 均複製到該專案的 Configuration 路徑。簽章 profile 只指定給 App，framework 不套用 App profile。未知的 App extension／額外 App 明確拒絕，需要未來增加各自的 profile mapping。

App 的最低版本必須恰為 17.0；內嵌二進位檔不得要求高於 17.0。這是靜態檢查，仍需 runtime 測試。無簽章 `.app` 不是可安裝的 release；腳本不會把它包成假 IPA。簽章檢查也不把 ad-hoc code signature 當作 distribution 憑證。

unsigned build、signed archive 與匯出 IPA 的實際 App `Info.plist` 均不得含 `NSAppTransportSecurity`，包括空字典與 Debug 的 `127.0.0.1` 例外；通過後報告記錄 `ats_key_absent: true`。文件共享的兩個實際 plist 布林值也必須為 true，報告記錄 `native_documents_enabled: true`。這些是產物檢查，不取代原生 Files 操作驗收。

`PrivacyInfo.xcprivacy` 宣告 App 自有設定的 UserDefaults（`CA92.1`）及計時用途的 SystemBootTime（`35F9.1`）。後者對應 `BrowserDownloadManager` 的實際 `systemUptime` 下載逾時計時；不收集裝置開機時間。發行檢查會讀取實際 App bundle 內的 manifest，驗證這兩個條目，報告記錄 `required_reason_entries_verified: true`。這是打包與已知 API 用途的檢查，不代表 App Store 審核或資料收集標籤已獲確認。[Apple 用途代碼](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

所有簽章資料只從此 repository 的下列 Actions secrets 取得，不讀取本機帳號憑證或提交中的金鑰檔，也不使用 environment secrets：

| Secret 名稱 | 需要由 owner 提供的既有資料 |
| --- | --- |
| `IOS_SIGNING_CERTIFICATE_BASE64` | 含 Apple Distribution 憑證及對應私鑰的既有 `.p12`，Base64 |
| `IOS_SIGNING_CERTIFICATE_PASSWORD` | 該 `.p12` 的非空密碼 |
| `IOS_PROVISION_PROFILE_BASE64` | 明確指定 `io.woowtech.assistant`、尚未過期的 distribution profile，Base64 |
| `IOS_TEAM_ID` | 與 profile 相符的 10 位 Team ID |
| `IOS_KEYCHAIN_PASSWORD` | 暫存鑰匙圈的非空密碼 |

`export_method=app-store-connect` 要求 App Store distribution profile；`release-testing` 要求含已登記裝置的 Ad Hoc profile。不接受 development、enterprise 或 wildcard profile。檢查 App ID 時支援舊帳號的 App ID prefix 與 Team ID 不同。

匯入的有效 distribution 身分必須與 profile 的 certificate SHA-1 相符且唯一。暫存 keychain 的搜尋清單會在 `finally` 還原，僅刪除本次安裝的 profile；同 UUID 檔案已存在時拒絕覆寫。簽章 secrets 不傳給 XcodeGen／xcodebuild 子程序環境；`security` 需要的密碼僅作參數傳入，命令、輸出及密碼不回顯。

簽章作業限 hosted ephemeral runner。一般錯誤會清理 keychain／profile；強制終止仍依賴 GitHub 銷毀 VM。工作流程最後移除本次 archive／IPA，只上傳不含憑證資料的 `report.json`，**不保存 IPA artifact**。App Store／TestFlight／GitHub Release 上傳均未實作，需依選定發行方式補上實際交付，不能把本地 export 稱為已發布。未使用 `-allowProvisioningUpdates`，不會自動註冊裝置或建立憑證。

Apple 自 2026-04-28 起要求 App Store Connect 上傳使用 Xcode 26 以上與 iOS 26 SDK 以上，因此簽章匯出使用 Xcode 26.2，並檢查 SDK；這不要求把 deployment target 提高到 iOS 26。[Apple SDK 要求](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)

## 整合介面與母任務修改點

在完整 Xcode／固定 XcodeGen 已可用的 Mac 執行：

```sh
python3 -B -m unittest discover -s scripts -p 'test_release_*.py' -v
python3 scripts/release_ios.py preflight
python3 scripts/release_ios.py preflight --signed
python3 scripts/release_ios.py build --output build/release
python3 scripts/release_ios.py build --signed --export-method app-store-connect --output build/release
python3 scripts/release_ios17.py --os 17.0.1 --download --output build/ios17
```

每次 build／runtime run 的 output 目錄必須不存在，避免沿用舊產物。成功退出 0；前置條件／建置／驗證失敗退出 1。`release_ios.py preflight --signed` 會實際暫存匯入、驗證並清理；不能只靠 secret 存在就宣告簽章可用。一般編譯及簽章子程序的原始輸出不回顯，以避免洩漏簽章資料；錯誤會指出失敗階段與退出碼，必要時由 owner 在安全環境另行診斷。

`release_ios17.py` 保留 `report.json`、`runtimes-before.json`，下載後另有 `runtimes-after.json`、`runtime-download.log`、`runtime-download-status.json`。每個耗時階段開始前會原子更新報告並即時輸出階段、UTC 時間與已用秒數；若 runner 中斷，已完成的 checkpoint 仍保留在磁碟。這不代表中斷後 GitHub 必定能完成 artifact 上傳。只有 XCTest 成功才設定 `runtime_tested: true`；版本由 simctl 的 `version` 精確比對，不能只比 identifier（例如 suffix `iOS-17-0` 可能實際是 17.0.1）。17.0、17.0.1、17.5 的證據必須分開記錄。預設為 17.0.1；若承諾精確 17.0，也要選 17.0 成功實跑。17.5 成功不能填補 17.0／17.0.1 的缺口。

`--test-scope`／workflow 的 `ios17_test_scope` 預設為 `all`，另有 `core`、`workspace`、`files`、`parity`、`startup`，供修正後的局部重測。報告會記錄範圍與 `selected_tests_succeeded`；只有 `all` 完整命令成功才會設 `runtime_tested: true`。局部成功不取代完整驗收，也不證明其他未選案例通過。完成後匯出原生介面 attachments 與 test-summary；若測試被中斷而 `.xcresult` 不完整，原始日誌仍保留。

母任務擁有的 `ios.yml` 若要加入持續最低版本檢查，請增加獨立 job，避免現有 matrix 的 runtime 選擇被混淆：

```yaml
minimum-ios17:
  runs-on: macos-15-intel
  timeout-minutes: 125
  env:
    DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer
  steps:
    - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
      with:
        persist-credentials: false
    - run: bash scripts/release_install_xcodegen.sh
    - run: python3 scripts/release_ios17.py --os 17.0.1 --download --output build/ios17
    - if: always()
      uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
      with:
        name: minimum-ios17-${{ github.run_id }}
        path: |
          build/ios17/*.json
          build/ios17/*.log
          build/ios17/*.xcresult
```

在整合提交的 CI 取得實際結果後才將此 job 加入 required checks。若 hosted 無法安裝／啟動，保存上述證據，改用已配置的自管 runner；不要 `continue-on-error` 後宣稱最低版本通過。自管可用 macOS 14＋Xcode 15.4＋預裝 iOS 17.0／17.0.1，或 Apple 支援範圍內較新的 Xcode 與 OS；由管理員完成 Xcode license／first launch、runtime 安裝，並以同一 runner 帳號確認 `simctl list runtimes --json` 中 `isAvailable: true`。本腳本只建立／刪除自己的 simulator，不控制實體手機或其他原生 App。

整合專案的 `SWIFT_VERSION` 已為 `5`，以符合 Swift 語言模式設定。README／VERIFICATION 僅依實際版本、日誌與 `.xcresult` 更新實測宣稱。

## 測試與待補輸入

本機已通過 25 個 Python tests，包含真實子程序的 secrets 環境隔離、錯誤輸出隔離、缺少 secrets 的 CLI 失敗，以及 profile／身分匹配、簽章清理、framework 設定隔離、最低版本、隱私 manifest 與 runtime 選擇；另驗證 ad-hoc seal 與不同 leaf certificate 不能通過 distribution 驗證。ATS 測試以真實 XML／binary plist 驗證拒絕 Debug loopback 設定、全域例外、空字典與錯誤型別，並驗證 unsigned／signed 無 ATS 的通過回報。簽章匯入清理、Mach-O 及產物憑證測試使用合成資料與替代命令；不代表真實 iOS 編譯或簽章已成功。實際本機 CLI 的缺少 Xcode 失敗路徑另確認退出 1、即時 preflight 訊息與 `runtime_tested: false` 的完整報告，沒有遺留半寫入的暫存報告。shell 語法、YAML 解析及 actionlint 1.7.12 已通過。

已實際下載並核對固定 XcodeGen 2.44.1 的 SHA-256，在本機暫存目錄產生真實專案，套用合成簽章設定後以 `plutil -lint` 驗證，確認 App 有 profile、其他 target 沒有 App profile。首次產生因 session 缺少 `USER` 失敗；只在驗證子程序補入 OS 帳號名稱後成功，未修改系統設定。此為專案產生／設定驗證，不是 Xcode 編譯。

本機未執行 iPhoneOS 編譯、simulator XCTest 或 signed archive，因為沒有完整 Xcode。GitHub 的 unsigned 與 runtime 實跑結果見本文件末段；`release_ios.py preflight` 的本機失敗僅代表本機缺少工具鏈。

尚需 owner 提供／完成的具體項目：

1. signed 模式缺少上述五個 repository secrets；需提供既有 distribution `.p12`、相符 profile／Team ID 與密碼，不建立或撤銷憑證，不將 secret 值傳入對話。現有兩個 repository secrets 與 Apple 簽章無關。
2. `d160a24` 的 unsigned 與 simulator 流程均已提交；這些工作不需 Apple secrets，也沒有 environment 核准閘門。
3. 17.0.1 與 17.5 分開執行，保存 run URL、runtime inventory、boot log 與 `.xcresult`；若 installer 失敗，保存 download log 與 status。17.5 成功不替代 17.0.1。
4. 如果 hosted 安裝／啟動失敗而需備援，須配置有 `woow-ios17` label 的 runner 與前述工具鏈；repository runners API 目前為空。USB 查核未見 iOS 裝置，Wi-Fi 配對狀態未確認，也沒有已確認的實體 iOS 17 測試裝置；本流程不連接實體裝置執行測試。

行為來源固定於 Mika `/tmp/woow-mika-memory-reference` 的 `0c172724`（本機短 SHA `0c17272`）；已對照 `core/.../memory/MemoryStore.kt` 的 unavailable 拒寫、更新需重新批准與 undo 行為。發佈檢查不驗證這些產品行為，也不代表 Mika parity；相關 app／memory 測試仍由其 owner 的實作與 XCTest 證據決定。

## Additional recorded results

`0092fc8` [unsigned-device 42758873943](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758873943) passed the same nine-binary and packaged-resource checks after the raw-address fix. It still reports `signature_verified: false`, `runtime_tested: false`, `uploaded: false`. Full reruns [17.0.1 42758764668](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758764668) and [17.5 42758809838](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758809838) on that revision are pending.

`39a13b0` [unsigned-device 42753499130](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42753499130) passed the actual Release build and packaged privacy-manifest audit: nine binaries, minimum OS 17.0, Xcode/SDK 26.2, `native_documents_enabled`, `ats_key_absent`, and `required_reason_entries_verified` all true. It remains unsigned, not installable, not runtime-tested and not uploaded for distribution.

Read-only reuse research found the related Apporo project's [signing configuration](https://github.com/WOOWTECH/Woow_apporo_ha_ios/blob/38e218afe425a1ae79353453058b2a3661fc6b66/Configuration/HomeAssistant.xcconfig) identifying team `W4UWZ8NP2P`; `QMQYCKL255` in older forks is upstream Home Assistant's team. Prior Omnigent Apporo Smart review records confirm another App Store submission existed, but provide no signing material for this bundle. No team has been copied into this project's build settings. The owner's intended team/distribution method and this App's matching profile/certificate remain unconfirmed.

Integrated `d160a24` [unsigned-device 42748369961](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748369961) passed: nine binaries, minimum OS 17.0, Xcode/SDK 26.2, `native_documents_enabled: true`, `ats_key_absent: true`. The report explicitly records `signature_verified: false`, `runtime_tested: false`, `uploaded: false`, and `unsigned-device-build-not-installable`.

[iOS 17.5 42748380772](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748380772) on `d160a24` installed 21F79, booted and completed XCTest: native/hosted 106 passed, one failed test containing two malformed-port assertions; UI 31 passed, 15 failed, ten explicitly skipped live-service cases. `runtime_tested: false` means the full acceptance suite did not pass, not that no App code executed.

[iOS 17.0.1 42748375007](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748375007) on `d160a24` installed 21A342 and booted. Recorded completed cases: native 96 passed/one failed, UI 26 passed/15 failed/ten skipped. The 55-minute build/test limit interrupted the startup suite before all remaining cases and the ten hosted WebKit cases could run. The `.xcresult`, logs and boot report are retained; incomplete cases are not counted as passes. The next run allows 80 minutes for build/test, 125 minutes for the job including download/boot/evidence upload; individual case allowances stay 240/300 seconds. Timeout and nonzero XCTest exit are now distinguished in the report and failure/cleanup behavior has synthetic regression coverage.

Both runs exposed the same invalid-port normalization and browser/PDF UI failures. `1153d5a` checks the original address before Foundation can erase an empty or overflowing port; the manual address entry now uses that boundary. Local Swift compilation, 1,034 direct address/range checks and syntax parsing passed. The updated native and hosted regression cases still require iOS execution. Other UI repairs are tracked in VERIFICATION.md.

`42745303603` on `7b11555` passed the unsigned iPhoneOS Release build and nine-binary minimum-OS audit: iOS 17.0, Xcode/SDK 26.2, Release ATS dictionary absent. This precedes the later explicit document-sharing plist and AppIcon integration and is not a signed artifact.

`42744261931` installed iOS 17.0.1 (21A342) successfully through the Apple installer, then timed out booting the disposable simulator after 300 seconds; no XCTest ran. The follow-up captures boot output with a 900-second bound.

The iOS AppIcon is rendered from the unchanged WOOW Android vector recorded in Configuration/Brand/SOURCE.json, with its original geometry and colors, into an opaque 1024-pixel asset. `swift scripts/render_app_icon.swift` reproduces it; no new logo is designed.
