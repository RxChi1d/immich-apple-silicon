# 本機部署記錄（rxchi1d）

這個分支是**這台 Mac 實際跑的東西的真相來源**，不是要送上游的 PR。

Homebrew 裝的 `immich-accelerator` 被就地改過。`brew upgrade` 會把改動蓋掉且不留痕跡，
這個分支存在的目的就是：升級之後知道當初改了什麼、為什麼、怎麼復原。

基底：`v1.12.0`（`28ea51f`）
更新：2026-08-19

---

## 部署概況

Split 模式：

```
vm-docker  192.168.50.5      immich-server / postgres / valkey
Mac        192.168.50.8      worker / native ML :3003 / dashboard :8420
           MacBook Air M1     8 GB / macOS 26.3
媒體        Synology DS920+   192.168.50.1:/volume2/immich，兩端都是 /data
```

---

## 這個分支上的四個 commit

| Commit | 內容 | 上游狀態 |
|---|---|---|
| `Check the ML port before starting an engine` | 啟動引擎前檢查 port，啟動路徑先認領 | **PR #148**，CI 全綠，待審 |
| `Signal a service's process group only when the group is ours` | `getsid` 判準的發訊號、`WEB_CONCURRENCY=1` | **PR #149**，疊在 #148 上，待審 |
| `Bound what one connection to the ML service can cost` | 連線資源上限：崩潰、fd 洩漏、大小、逾時 | **PR #147**，CI 全綠，待審 |
| `Let the encoder be chosen separately from the decoder` | ffmpeg wrapper 硬解 + 軟編 | **本機專用，不送上游** |

前三個如果被上游合併，這個分支就只剩最後一個。

---

## 實際套用到機器上的東西

| 項目 | 位置 | `brew upgrade` 後 |
|---|---|---|
| `__main__.py`（含 #148 + #149） | Cellar `libexec/immich_accelerator/` | **會掉**，備份 `.bak-stock-1120` |
| `ffmpeg-wrapper.sh`（軟編） | 同上 | **會掉**，備份 `.bak-stock-1120` |
| 自建 native-ml（含 #147） | `~/.immich-accelerator/native-ml/` | 執行檔留著，但 `native_ml_dir` 會被 `setup --url` 清掉 |
| 繁中 geodata | `/build/geodata` + server 的 `node_modules` | 不受影響（切 Immich 版本會影響 i18n 那半） |

---

## `brew upgrade` 之後的檢查清單

```bash
brew info immich-accelerator | head -1
CELLAR=$(brew --prefix immich-accelerator)/libexec/immich_accelerator

# 1. #147/#148/#149 有沒有被上游合併（合併了就只要留 wrapper）
grep -c "ml_port_state" "$CELLAR/__main__.py"        # 0 = 還沒合併，要重套

# 2. 重套 Python 那兩個檔
cd ~/src/fork/immich-apple-silicon
git worktree add /tmp/wt-deploy deploy/rxchi1d
cp /tmp/wt-deploy/immich_accelerator/__main__.py       "$CELLAR/__main__.py"
cp /tmp/wt-deploy/immich_accelerator/ffmpeg-wrapper.sh "$CELLAR/ffmpeg-wrapper.sh"

# 3. native-ml：確認 config 指向自建版，不在的話重建
python3 -c 'import json,pathlib;print(json.loads((pathlib.Path.home()/".immich-accelerator/config.json").read_text()).get("native_ml_dir"))'
cd /tmp/wt-deploy/native-ml && swift build -c release && bash scripts/build_bundle.sh ~/.immich-accelerator/native-ml

# 4. 重啟（不能用 stop && start，plist 有 KeepAlive 會搶 port 3003）
lsof -nP -iTCP:3003 -sTCP:LISTEN     # 有 LISTEN 但 services 說 stopped → 孤兒，先 kill
brew services restart immich-accelerator

# 5. 驗證三個修正都在
printf 'GET /ping HTTP/1.1\r\nHost: x\r\nContent-Length:\r\n\r\n' | nc -w 3 127.0.0.1 3003
#    要看到 400 Bad Request 且行程存活 = #147 生效
grep -c "ml_port_state" "$CELLAR/__main__.py"        # 非 0 = #148/#149 生效
grep "idle model eviction" ~/.immich-accelerator/logs/ml.log | tail -1
```

---

## `immich-accelerator update` 切換 Immich 版本後

跟 `brew upgrade` 是不同維度。geodata 本體在 `/build/geodata` 不受影響，
但 zh-TW 的 i18n 國家名稱裝在 `server/<version>/node_modules`，換版本要重裝。

---

## 尚未處理的已知問題

**iPhone 空間音訊（APAC）導致轉檔失敗。** iPhone 16 Pro 的 4K HDR 影片帶第二條
APAC 音軌，Immich 挑了它（`-map 0:2`）而不是可解碼的 AAC（`0:1`），
jellyfin-ffmpeg 沒有 APAC 解碼器，開輸出檔時 EINVAL。

這是 **Immich server 的問題**，跟 accelerator 和轉碼器都無關 ——
硬編、軟編都一樣失敗，只把 `-map 0:2` 換成 `-map 0:1` 就成功。
抽樣 400 個影片有 13 個含 APAC（3.25%）。目前 `videoConversion` 有 12 個 failed。

**native ML 的 fd 洩漏沒有根治。** #147 大幅減輕但未消除：每 3000 次
被 RST 中斷的請求仍留下 11–29 個 CLOSED socket，不回收，原因未查明。
候選解法見 PR #147 的討論。
