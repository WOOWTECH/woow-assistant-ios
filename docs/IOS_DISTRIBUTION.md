# iOS 簽章與最低版本驗證

查核日期：2026-11-10。基準提交：`918a8df`。這份文件與 `release-ios.yml` 提供可執行的建置／驗證流程；目前沒有 iOS 17 實測成功、簽章成功或可發佈的宣稱。

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

Apple 提供 `xcodebuild -downloadPlatform iOS -buildVersion <版本>` 安裝指定 runtime。未預載不代表無法下載；本機無 Xcode，整合提交的 hosted CI 尚待執行，**尚未取得 hosted 安裝失敗證據**，也不宣稱安裝必定可行。流程會實際嘗試，下載限時 20 分鐘，保留退出碼／逾時狀態與前後 runtime inventory。[Apple 安裝說明](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

另已實際讀取 Apple 公開 runtime catalog，仍列 iOS 17.0（21A328，7,559,529,352 bytes）、17.0.1（21A342，7,210,691,623 bytes）、17.5（21F79，7,336,630,623 bytes），標示 `authentication: virtual`。對三個原始下載來源進行無認證 HEAD 均轉到 `developer.apple.com` 的 `text/html` 頁面；這不是 DMG 下載成功，也不能推論 Xcode installer 必須另登入。沒有下載大型映像或取得任何帳號認證；流程使用 Apple installer，不用 `curl` 把 HTML 當 runtime。[Apple runtime catalog](https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex)

## 已實作的流程

`.github/workflows/release-ios.yml` 只有手動 `workflow_dispatch`，`contents: read`，checkout 不保存認證。使用者已授權 push 與 CI；母任務將在整合提交上執行 `unsigned-device` 與 `ios17-hosted`。兩個 environment 閘門已移除，不需另取得 owner dispatch 核准。

| mode | 工具鏈 | 執行內容／產物 |
| --- | --- | --- |
| `unsigned-device`（預設） | `macos-15-intel`、Xcode 26.2 | Release `iphoneos` arm64 編譯；檢查實際 build settings、App Info.plist、App／framework／Swift dylib 的 Mach-O 最低版本；不產生 IPA |
| `signed-export` | 同上；repository Actions secrets | 既有 distribution 憑證與 profile 預檢、手動簽章 archive、`destination=export` 本地 IPA 匯出；驗證簽章完整性及實際 leaf certificate |
| `ios17-hosted` | `macos-15-intel`、Xcode 16.4 | 指定 runtime 若缺少便下載；建立專用 iPhone 15 simulator，執行現有 `WoowAssistant` 完整 XCTest scheme，保存 `.xcresult`／測試 log |
| `ios17-self-hosted` | `[self-hosted, macOS, woow-ios17]`，使用 runner 已選定的 Xcode | 僅用已預裝的指定 runtime；缺少即失敗，不自動改用其他 OS |

建置與測試在獨立產生的 `.xcodeproj` 進行，不修改 `project.yml`。簽章 profile 只指定給 App，framework 不套用 App profile。未知的 App extension／額外 App 明確拒絕，需要未來增加各自的 profile mapping。

App 的最低版本必須恰為 17.0；內嵌二進位檔不得要求高於 17.0。這是靜態檢查，仍需 runtime 測試。無簽章 `.app` 不是可安裝的 release；腳本不會把它包成假 IPA。簽章檢查也不把 ad-hoc code signature 當作 distribution 憑證。

unsigned build、signed archive 與匯出 IPA 的實際 App `Info.plist` 均不得含 `NSAppTransportSecurity`，包括空字典與 Debug 的 `127.0.0.1` 例外；通過後報告記錄 `ats_key_absent: true`。這項檢查僅驗證產物 plist，不宣稱已排除所有 Debug fixture 符號。

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

簽章作業限 hosted ephemeral runner。一般錯誤會清理 keychain／profile；強制終止仍依賴 GitHub 銷毀 VM。工作流程最後移除本次 archive／IPA，只上傳不含憑證資料的 `report.json`，**不保存 IPA artifact**。App Store／TestFlight／GitHub Release 上傳均未實作，亦不在本次範圍；未使用 `-allowProvisioningUpdates`，不會自動註冊裝置或建立憑證。

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

`release_ios17.py` 保留 `report.json`、`runtimes-before.json`，下載後另有 `runtimes-after.json`、`runtime-download.log`、`runtime-download-status.json`。只有 XCTest 成功才設定 `runtime_tested: true`；版本由 simctl 的 `version` 精確比對，不能只比 identifier（例如 suffix `iOS-17-0` 可能實際是 17.0.1）。17.0、17.0.1、17.5 的證據必須分開記錄。預設為 17.0.1；若承諾精確 17.0，也要選 17.0 成功實跑。17.5 成功不能填補 17.0／17.0.1 的缺口。

母任務擁有的 `ios.yml` 若要加入持續最低版本檢查，請增加獨立 job，避免現有 matrix 的 runtime 選擇被混淆：

```yaml
minimum-ios17:
  runs-on: macos-15-intel
  timeout-minutes: 90
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

母任務另需檢查 `project.yml` 的 `SWIFT_VERSION`：基準值為 `5.9`，但 Swift 語言模式不是 compiler release number；應用 `5` 並使用足夠新的 compiler，或以實際 Xcode build settings 證明既有設定有效。本任務未改此檔，也不以命令列覆蓋掩蓋該問題。README／VERIFICATION 僅能在有 `.xcresult` 與實際 OS version 後更新實測宣稱。

## 測試與待補輸入

本機已通過 20 個 Python tests，包含真實子程序的 secrets 環境隔離、錯誤輸出隔離、缺少 secrets 的 CLI 失敗，以及 profile／身分匹配、簽章清理、framework 設定隔離、最低版本與 runtime 選擇；另驗證 ad-hoc seal 與不同 leaf certificate 不能通過 distribution 驗證。ATS 測試以真實 XML／binary plist 驗證拒絕 Debug loopback 設定、全域例外、空字典與錯誤型別，並驗證 unsigned／signed 無 ATS 的通過回報。簽章匯入清理、Mach-O 及產物憑證測試使用合成資料與替代命令；不代表真實 iOS 編譯或簽章已成功。shell 語法、YAML 解析及 actionlint 1.7.12 已通過。

已實際下載並核對固定 XcodeGen 2.44.1 的 SHA-256，在本機暫存目錄產生真實專案，套用合成簽章設定後以 `plutil -lint` 驗證，確認 App 有 profile、其他 target 沒有 App profile。首次產生因 session 缺少 `USER` 失敗；只在驗證子程序補入 OS 帳號名稱後成功，未修改系統設定。此為專案產生／設定驗證，不是 Xcode 編譯。

本機未執行 iPhoneOS 編譯、simulator XCTest 或 signed archive，因為沒有完整 Xcode。push 與 CI 已獲授權；母任務待整合後執行 unsigned／iOS 17 流程，尚無該整合提交的實測結果。`release_ios.py preflight` 的本機失敗應視為可重現的缺少工具鏈證據。

尚需 owner 提供／完成的具體項目：

1. signed 模式缺少上述五個 repository secrets；需提供既有 distribution `.p12`、相符 profile／Team ID 與密碼，不建立或撤銷憑證，不將 secret 值傳入對話。現有兩個 repository secrets 與 Apple 簽章無關。
2. 母任務將在整合提交上執行 `unsigned-device` 與 `ios17-hosted`；unsigned／simulator 不需 Apple secrets，也沒有 environment 核准閘門。
3. `ios17-hosted` 優先測 17.0.1（必要時另試 17.0／17.5），保存 run URL、runtime inventory 與 `.xcresult`；若 Apple installer 失敗，保存 download log 與 status。不得把尚未 dispatch 說成安裝失敗。
4. 如果 hosted 安裝／啟動失敗而需備援，須配置有 `woow-ios17` label 的 runner 與前述工具鏈；repository runners API 目前為空。USB 查核未見 iOS 裝置，Wi-Fi 配對狀態未確認，也沒有已確認的實體 iOS 17 測試裝置；本流程不連接實體裝置執行測試。

行為來源固定於 Mika `/tmp/woow-mika-memory-reference` 的 `0c172724`（本機短 SHA `0c17272`）；已對照 `core/.../memory/MemoryStore.kt` 的 unavailable 拒寫、更新需重新批准與 undo 行為。發佈檢查不驗證這些產品行為，也不代表 Mika parity；相關 app／memory 測試仍由其 owner 的實作與 XCTest 證據決定。

## Additional recorded results

`42745303603` on `7b11555` passed the unsigned iPhoneOS Release build and nine-binary minimum-OS audit: iOS 17.0, Xcode/SDK 26.2, Release ATS dictionary absent. This precedes the later explicit document-sharing plist and AppIcon integration and is not a signed artifact.

`42744261931` installed iOS 17.0.1 (21A342) successfully through the Apple installer, then timed out booting the disposable simulator after 300 seconds; no XCTest ran. The follow-up captures boot output with a 900-second bound.

The iOS AppIcon is rendered from the unchanged WOOW Android vector recorded in Configuration/Brand/SOURCE.json, with its original geometry and colors, into an opaque 1024-pixel asset. `swift scripts/render_app_icon.swift` reproduces it; no new logo is designed.
