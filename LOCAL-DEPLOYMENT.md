# 本機部署記錄（rxchi1d）

這個分支是**這台 Mac 實際跑的東西的真相來源**，不是要送上游的 PR。

Homebrew 裝的 `immich-accelerator` 被就地改過。`brew upgrade` 會把改動蓋掉且不留痕跡，
這個分支存在的目的就是：升級之後知道當初改了什麼、為什麼、怎麼復原。

基底：`v1.13.0`（`0dfb1ed`）
更新：2026-08-20

---

## 部署概況

Split 模式。核心已於 2026-08-19 從 9950X 遷到 PVE 的 vm-docker：

```
vm-docker  192.168.50.5      immich-server / postgres / valkey
Mac        192.168.50.8      worker / native ML :3003 / dashboard :8420
           MacBook Air M1     8 GB / macOS 26.3
媒體        Synology DS920+   192.168.50.1:/volume2/immich，兩端都是 /data
```

---

## 這個分支上只剩一個 commit

| Commit | 內容 | 上游狀態 |
|---|---|---|
| `Let the encoder be chosen separately from the decoder` | ffmpeg wrapper 硬解 + 軟編 | **本機專用，不送上游** |

v1.12.0 到 v1.13.0 之間，先前分支上的另外三個 commit 全部被上游合併：

| 原本的 commit | 上游 |
|---|---|
| `Check the ML port before starting an engine` | PR #148（v1.13.0） |
| `Signal a service's process group only when the group is ours` | PR #149（v1.13.0） |
| `Bound what one connection to the ML service can cost` | PR #147（v1.13.0） |

模型閒置卸載（PR #137）更早，在 v1.12.0 就進去了。

舊分支保留在 `deploy/rxchi1d-v1.12.0-archive`。

---

## 實際套用到機器上的東西

**只有一項。** 其餘全是原廠。

| 項目 | 位置 | `brew upgrade` 後 |
|---|---|---|
| `ffmpeg-wrapper.sh`（軟編） | Cellar `libexec/immich_accelerator/` | **會掉**，要重套 |

已經退役、不再需要的：

| 項目 | 為什麼不需要了 |
|---|---|
| `__main__.py` 的就地修改 | #148 / #149 已進 v1.13.0，Cellar 現在是原廠 |
| 自建 native-ml + `native_ml_dir` | #137（v1.12.0）+ #147（v1.13.0）都進上游了。已從 `config.json` 移除，改用 Cellar 的原廠執行檔，舊的留在 `~/.immich-accelerator/native-ml.selfbuilt-1120` |

不受 `brew upgrade` 影響的：

| 項目 | 位置 | 什麼時候會失效 |
|---|---|---|
| 繁中 geodata | `/build/geodata` | 不受影響 |
| 繁中 i18n 國名 | server 的 `node_modules/i18n-iso-countries` | **切換 Immich 版本時**（`immich-accelerator update`）要重裝 |
| `config.json` | `~/.immich-accelerator/` | `setup --url` 會清掉不在 `_PRESERVED_CONFIG_KEYS` 裡的 key |

---

## `brew upgrade` 之後的檢查清單

```bash
brew info immich-accelerator | head -1
CELLAR=$(brew --prefix immich-accelerator)/libexec/immich_accelerator

# 1. 確認 wrapper 被蓋回原廠了（0 = 被蓋掉，要重套）
grep -c "SW_ENCODE" "$CELLAR/ffmpeg-wrapper.sh"

# 2. 重套（先備份原廠版）
cd ~/src/fork/immich-apple-silicon
git fetch --all --tags
cp "$CELLAR/ffmpeg-wrapper.sh" "$CELLAR/ffmpeg-wrapper.sh.bak-stock"
cp immich_accelerator/ffmpeg-wrapper.sh "$CELLAR/ffmpeg-wrapper.sh"
chmod 755 "$CELLAR/ffmpeg-wrapper.sh"
bash -n "$CELLAR/ffmpeg-wrapper.sh"

# 3. 順手確認上游有沒有把 wrapper 收上去（有的話這個分支就可以退休）
git show <新tag>:immich_accelerator/ffmpeg-wrapper.sh | grep -c SW_ENCODE

# 4. 重啟（不要用 stop && start，plist 有 KeepAlive 會搶 port 3003）
lsof -nP -iTCP:3003 -sTCP:LISTEN     # 有 LISTEN 但 services 說 stopped → 孤兒，先 kill
brew services restart immich-accelerator

# 5. 驗證 wrapper 真的生效
grep -o 'SW_ENCODE="${IMMICH_ACCELERATOR_SW_ENCODE:-[01]}"' ~/.immich-accelerator/bin/ffmpeg
```

`~/.immich-accelerator/bin/ffmpeg` 是 accelerator 每次 `start` 從 Cellar 複製產生的，
所以第 5 步是在確認 Cellar 那份真的被讀到。

---

## 為什麼要軟體編碼

wrapper 把 `USE_HW`（硬體**解碼**）和 `USE_VTENC`（硬體**編碼**）拆開，
讓解碼留在媒體引擎、編碼走 libx264。

M1 Air 上轉 720p，以縮放後的原檔為基準對齊 SSIM：

```
libx264 -preset veryfast -crf 23    0.75 Mbps   SSIM 0.9544   379% CPU
h264_videotoolbox -q:v 55           1.62 Mbps   SSIM 0.9546   279% CPU
```

同畫質下硬體編碼要 2.2 倍位元率，而且不比較快。持續滿載十分鐘，
libx264 從 345 掉到 330 fps（-4.4%），VideoToolbox 從 311 到 314 fps 持平，
macOS 沒有記錄任何過熱警告 —— 軟體仍然勝出（11.4x vs 10.7x realtime）。

解碼那半一定要保留硬體：把 `-hwaccel videotoolbox` 一起拿掉，
同一個軟體編碼從 379% CPU 變成 751%，因為軟解 1920x1440 HEVC 蓋過其他所有成本。

`IMMICH_ACCELERATOR_SW_ENCODE=0` 可以退回全 VideoToolbox。

---

## 復原

```bash
# 只要 wrapper 退回原廠
CELLAR=$(brew --prefix immich-accelerator)/libexec/immich_accelerator
cp "$CELLAR/ffmpeg-wrapper.sh.bak-stock-1130" "$CELLAR/ffmpeg-wrapper.sh"
brew services restart immich-accelerator

# 或不動檔案，用環境變數關掉（需要 plist 或 shell 帶入）
IMMICH_ACCELERATOR_SW_ENCODE=0

# 退回自建 native-ml（正常情況不需要，原廠已含 #137 + #147）
mv ~/.immich-accelerator/native-ml.selfbuilt-1120 ~/.immich-accelerator/native-ml
# 然後把 "native_ml_dir": "/Users/rxchi1d/.immich-accelerator/native-ml" 加回 config.json
```
