# limpet

limpet 是一個 macOS 選單列 App，透過 [rclone](https://rclone.org/) 把本機資料夾單向鏡像（本機 → 遠端）到遠端目的地。rclone 支援的遠端都可以當目的地。

## 目前具備的功能

- **單向本機 → 遠端鏡像。** 每個設定檔會透過 `rclone sync` 把一個本機目錄同步到遠端路徑；遠端最後一定會跟本機來源一致。
- **選單列狀態顯示。** 選單列圖示會顯示閒置／同步中／錯誤／硬碟未掛載等狀態、即時傳輸進度，以及最近同步的檔案清單。
- **多組設定檔。** 可以設定任意數量的「本機資料夾 → 遠端」配對，各自有獨立的排程、啟用／停用狀態、通知靜音設定。
- **透過 launchd 在背景執行。** 每個啟用中的設定檔都會在 `~/Library/LaunchAgents` 安裝一個 agent，依排程執行同步，App 不是使用中視窗時同步仍會持續。
- **命令列工具。** `~/.local/bin/limpet` 這個 CLI shim 提供跟 GUI 相同的設定檔管理、健康檢查與手動同步功能，讓腳本或 agent 不用開視窗就能操作。
- **檔案化、可編輯的設定。** 設定檔與設定值以 JSON 形式存在 `~/.config/limpet/` 下，並依照一份已提交的 JSON Schema 驗證；手動改檔案，會跟按 GUI 的「儲存」走同一套流程，立即生效。

> **即時監看仍在開發中。** 目前 FSEvents 的即時觸發只在選單列 App 有開啟時才會運作；App 關閉後，launchd agent 會退回成定期輪詢。計劃中的改動會把排程與監看的所有權整個搬進每個設定檔自己的 launchd agent，讓即時同步在 App 關閉時也能持續運作。

## 需求

- macOS 13.0 以上
- 已安裝並至少設定好一個遠端的 [rclone](https://rclone.org/)（`brew install rclone`，再執行 `rclone config`）

limpet 會自動偵測 Homebrew、`/usr/local/bin`、`/usr/bin` 以及常見的 nix 安裝路徑下的 rclone。

## 從原始碼建置

目前還沒有簽署過的發行版，也沒有 Homebrew cask，請自行建置：

```bash
git clone https://github.com/Nanako0129/limpet.git
cd limpet
xcodebuild -project limpet.xcodeproj -scheme limpet \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath build build
open build/Build/Products/Debug/limpet.app
```

建出來的 App 沒有簽署。

## `limpet` CLI

App 每次啟動都會在 `~/.local/bin/limpet` 安裝一份 shim（記得把 `~/.local/bin` 加進 `PATH`）。不管 GUI App 有沒有在執行都能用，因為所有會改變狀態的指令都是走跟 GUI 相同的檔案化設定。

| 指令 | 用途 |
| --- | --- |
| `limpet doctor` | 健康檢查：rclone 是否存在、schema 是否已安裝、agent 是否已載入、殘留鎖檔、遠端可否連線。 |
| `limpet status [name\|id]` | 每個設定檔一行：啟用狀態、agent 是否已載入、是否執行中、最後結果。 |
| `limpet profiles` | 列出設定檔（不含憑證）。 |
| `limpet profile show <name\|id>` | 印出某個設定檔的完整 JSON 設定。 |
| `limpet logs <name\|id> [--follow]` | 印出或持續追蹤某個設定檔的同步記錄。 |
| `limpet test-remote <name\|id>` | 測試某個設定檔的遠端是否可連線。 |
| `limpet listremotes` | 直接轉呼叫 `rclone listremotes`。 |
| `limpet profile create --from <file>` / `-` | 從一個 `.profile.json` 檔或標準輸入建立設定檔。 |
| `limpet profile enable` / `disable` / `delete <name\|id>` | 啟用、停用或刪除設定檔。 |
| `limpet profile set <name\|id> <key> <value> ...` | 編輯既有設定檔的欄位。 |
| `limpet install` / `reinstall <name\|id>` | （重新）安裝設定檔的 launchd agent。 |
| `limpet sync <name\|id>` | 立即執行一次同步並等待完成。 |

## 檔案位置

| 路徑 | 內容 |
| --- | --- |
| `~/.local/bin/limpet` | CLI shim |
| `~/.local/bin/limpet-sync.sh` | 所有設定檔共用的同步腳本 |
| `~/.config/limpet/profiles/{shortId}.profile.json` | 設定檔本體（可編輯） |
| `~/.config/limpet/profiles/{shortId}.json` | 衍生的、僅供腳本用的設定 |
| `~/.config/limpet/settings.json` | App 設定（可編輯） |
| `~/.config/limpet/schema/*.schema.json` | 上述檔案用的 JSON Schema |
| `~/.local/log/limpet-sync-{shortId}.log` | 各設定檔的同步記錄 |
| `/tmp/limpet-sync-{shortId}.lock` | 鎖檔（避免同一設定檔同時跑兩份） |
| `~/Library/LaunchAgents/com.nanako.limpet.watch.{shortId}.plist` | 各設定檔的 launchd agent |

## limpet 刻意不做的事

limpet 只做單向鏡像。沒有雙向同步、沒有版本紀錄或還原、沒有備援遠端、沒有掛載模式、沒有 Finder 擴充功能、沒有自動更新，也沒有遙測。

## 開發

```bash
xcodebuild -project limpet.xcodeproj -scheme limpet \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

目前沒有 XCTest target；`limpet --self-test`（僅限 Debug build）會執行涵蓋設定檔持久化、遷移、設定整合器與 CLI 的斷言測試套件。`scripts/check-schema-in-sync.sh` 檢查已提交的 JSON Schema 跟 `SyncProfile` 模型是否一致，不一致就失敗。

## 授權

MIT，詳見 [LICENSE](LICENSE)。
