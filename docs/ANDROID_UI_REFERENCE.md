# 渥屋助理 iOS 介面對照基準

本專案的介面基準是 [WOOWTECH 渥屋助理 Android 原始碼](https://github.com/WOOWTECH/woowtech_mika_smart_app)，上游架構參考 [Mika](https://github.com/wangzan101/Mika)。iOS 以原生 SwiftUI 實作，保留已授權的模型對話、瀏覽器、MCP、技能、記憶與資料等功能。介面對照時同時核對畫面與實際操作結果。

## 參考版本與實測邊界

- Android 主線參考提交：`de5be358c4e24b7eed46a95e46edf35a86881bff`，來源與 24 個介面檔案的 SHA-256 記於 [android-ui-reference.json](android-ui-reference.json)。
- 另以官方公開的 `v0.1.37-woow.7` arm64 APK 實際查核發行品；其 tag 為 `da8e5781318f159ef6ebb714db51e6bcd2946449`，與上述主線提交不同。參考畫面和行為時須註明採用的版本。
- 使用 [Craft Anything](https://github.com/storytold/craft-anything) CLI 0.6.0 的 `android-package-show` 與 `android-resources-read` 檢查該 APK。前者辨識出 `io.woowtech.agent`、版本 `0.1.37-woow.7`，對 908 個項目回報完整套件清查；後者確認 APK 含繁中資源，但本次只讀取前 30 項。此結果是套件與資源檢查，不能證明任何 iOS 畫面或功能已對齊。
- 使用者提供的 Android 截圖顯示設定與「記憶與資料」頁的深色外觀；其中部分設定頁截圖有勾選標記。標記與個人資料不能當成介面素材。截圖及原始碼均須作為實機對照依據。
- 第一個安裝至 iPad 的 iOS 提交為 `5084968`。該版本在 iPadOS 26.6.1 成功建置、簽章、安裝並啟動，但原設定僅包含 iPhone 介面家族，iPad 以相容模式顯示；使用者已指出畫面與渥屋助理差異過大，因此不作為視覺驗收通過的證據。

## 已確認的設計依據

- Android 的主要入口是對話頁與側欄，導覽定義見 `app/src/main/java/com/wangzan101/mika/ui/Navigation.kt`、`ChatScreen.kt` 和 `ChatDrawer.kt`。原 iOS `ContentView.swift` 使用五個底部分頁，需要重做資訊層級與入口。
- 品牌色取自 `app/src/woowtech/resources/brand.properties`：淺色強調色 `#4069FB`，深色強調色 `#6183FC`；淺／深色頁面與卡片色取自 `ui/theme/Colors.kt`。字級、間距和圓角取自 `ui/theme/Tokens.kt`，不能僅以色碼宣稱視覺一致。
- Android 的「記憶與資料」依使用者提供的畫面包含「記憶、技能、待確認」區段；內容與可操作項目仍須對照 iOS 真實資料及目前的支援範圍。
- 功能範圍依使用者先前選擇：一般對話、模型、MCP、技能、記憶與瀏覽器。Android 的手機操作、其他 App 控制與螢幕錄影不列入 iOS 功能。

## 後續更新如何比對

在更新 Android checkout 後執行：

```sh
python3 scripts/check_android_ui_reference.py --android-repo /path/to/woowtech_mika_smart_app
```

GitHub Actions 也提供手動執行的 `Android UI reference check`，從 Android 主線取得最新來源後執行同一檢查。

工具逐一核對固定的來源檔內容，列出變動或遺失檔案；提交不同但所列檔案不變時仍會顯示兩個提交供人工確認。它不會自動更新基準，也不會偵測清單之外新增的介面檔案。檢查到變動後，應審閱 Android 差異、更新相應 iOS 實作與驗證，再經審閱更新基準。外觀驗收應在相近尺寸、語言、明暗模式與資料狀態下，對照 Android 與 iPhone／iPad 截圖，並實測入口與操作。
