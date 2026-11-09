# 渥屋助理 iOS

獨立的 iOS 17+ 渥屋助理。此專案以 Mika／渥屋 Android 版作為**行為規格**，以 Swift 重建；不搬用 Android 的手機控制、無障礙、螢幕錄影或 ADB 能力。

## 目前狀態

這是開發骨架，不是可交付的助理。已有介面導覽、任務狀態機、瀏覽器網址初步檢查、資料合約與測試。模型串流、真正的 WebKit 瀏覽、MCP、Skills、儲存與通知尚未串接；介面會明確標示未實作，不會模擬成功。

## 第一版目標範圍（尚未完成）

- 模型對話、串流任務狀態、記憶與附件。
- 受控的 MCP、Skills 與遠端計算工作。
- 內建 WebKit 瀏覽器：分頁、歷史、書籤、下載、上傳與頁面問答。
- 通知、語言／外觀與隱私設定。

不包含其他 App 操作、浮動膠囊、無障礙自動化、螢幕錄影、連接電腦控制、任意本機 Shell／Python／Node 執行。

## 本機開發

需要完整 Xcode 15+、Python 3 與 XcodeGen 2.44.1。CI 固定使用 Xcode 16.4／iOS 18.5 模擬器；這不取代 iOS 17 真機驗證。

```sh
make project
make core-test
make test
```

`make test` 自動選擇本機已安裝且可用的 iOS 17+ iPhone 模擬器。只有 Command Line Tools 的主機可做部分 Swift 檢查，但無法建置或執行 iOS UI。CI 會保留測試日誌與 `.xcresult`，失敗時也會上傳。

## 瀏覽器邊界

規劃由本機 WebKit 處理使用者可見的瀏覽與登入；Mika 的 CDP 等本機無法直接對齊的能力，預計由明確標示、使用者同意的遠端 Browser Gateway 補足。目前只有介面合約，沒有實作 Gateway，也未證明瀏覽器完整對齊。不得自動搬移 iPhone 的 Cookie、密碼、OTP 或 Passkey。

網址政策只是字串與 IP 字面值的初步檢查，不是完整 SSRF 防線；接入網路時仍須檢查 DNS、重新導向與子資源。合約中的確認布林值也不是安全授權憑證。
