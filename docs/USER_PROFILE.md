# 個人檔案

行為來源為 Mika `0c172724f3f0c96f7345262588072f6e95db1138` 的 `core/memory/ProfileStore.kt` 與 `general/ProfileEdit.kt`。Swift 版本保留 20 條現用紀錄、每條 160 UTF-16 單位、單句及敏感資料檢查。取代或刪除需片段只在一條現用紀錄中出現一次；舊列改為 superseded，歷史不注入模型。這不是手機控制功能。

「記憶與資料 → 個人檔案」可新增、編輯及刪除，也可查看已替換／刪除歷史。資料沿用既有 AES-GCM 學習檔與本裝置 Keychain；先修改副本，再完成原子儲存，成功才更新畫面。v1／v2 舊檔沒有 profile 欄位時視為空檔案；欄位損毀或無法讀取時保留原檔、拒絕覆寫。

一般／MCP 對話在開始時取得個人檔案快照，置於目前要求之前的 user-role 參考資料。當輪要求優先，修改僅影響後續對話。「使用記憶」關閉時不加入快照，但保留資料。既有兩次確認的完整清除包含 profile 與歷史，並輪替學習金鑰；模型與 MCP 設定不受影響。

本機實測：核心 199 項斷言（含 CR/LF 新增、替換及解碼回歸）；實際 LearningStore／AES-GCM 保存、重開、寫入失敗回滾、舊檔遷移、開關與清除輪替共 58 項斷言。持久化測試只替換 KeyStore 與瀏覽器工具目錄，不存取個人 Keychain。相同持久化斷言亦接入 hosted XCTest。`1ea3d08` 的五個原生核心方法及一個 hosted 保存方法在三種模擬器全部通過；精確 iOS 17.0.1 原生核心亦通過。`dabe9bf` 的真實模型回憶／停用流程通過 1/1：兩次重開後分別回覆已存偏好及 UNKNOWN，停用不刪除資料。`1ea3d08` 介面測試曾有歷史列識別碼與逾時失敗，`faf7536` 修正後拆為五個 Profile 案例，正在與其他記憶流程重測。詳見[驗證紀錄](VERIFICATION.md)。

尚未接入 Mika `profile_edit(op,text,match,quote)` 模型工具、模型自行整理個人檔案，以及所有獨立技能／瀏覽器工作流程的個人檔案注入。使用者直接編輯入口與一般對話整合不代表這些路徑已通過。

可重跑：

```sh
bash scripts/CheckUserProfileState.sh
bash scripts/CheckUserProfileStore.sh
```
