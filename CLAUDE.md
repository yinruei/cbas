# CBAS — 可轉債營收動能儀表板

單頁靜態網站：台灣上櫃轉（交）換公司債清單 × 標的個股近 12 個月營收趨勢。
部署於 GitHub Pages：https://yinruei.github.io/cbas/ （repo: yinruei/cbas）

## 架構

- `index.html` — 全部的 UI 與邏輯（無建置步驟、無外部 JS 相依；字型用 Google Fonts）。
  以 `fetch("data/*.json")` 載入資料，所以**必須經 HTTP 服務**開啟（`python -m http.server`），
  直接 file:// 開會因 CORS 載不到資料。
- `data/bonds.json` — 可轉債清單（約 386 筆）。
- `data/monthly_revenue.json` — 上市＋上櫃約 1,856 家公司的月營收序列。
- `scripts/update-data.ps1` — 重抓以上兩檔。Windows PowerShell 5.1 可跑；
  **此檔必須保持 UTF-8 with BOM**（PS 5.1 讀無 BOM 檔會當 ANSI，中文字串literal 會壞）。

## 資料來源與格式

### bonds.json ← 櫃買中心 OpenAPI `bond_ISSBD5_data`
- ISSBD5 = 轉換公司債資料集（ISSBD1/3/4/10 為其他債種，schema 相同）。
- 已過濾：僅留 `OfferingMethod=7`（公開發行）且 4 碼 `IssuerCode`；私募（=8）排除。
- 公開發行可轉債的 `IssueDate` 恆等於 `ListingDate`（驗證過 0 筆例外）。
- 日期為西元 `YYYY-MM-DD`。網頁上民國/西元換算：民國年 + 1911。
- 金額單位：元。`convPrice`/`putPrice`：元；`couponRate`：%。

### monthly_revenue.json ← MOPS `t21sc03` 月報表
- URL 樣式：`https://mopsov.twse.com.tw/nas/t21/{sii|otc}/t21sc03_{民國年}_{月(不補零)}_0.html`
  — host 必須是 **mopsov**（mops.twse.com.tw 回 404）。頁面編碼 **Big5 (CP950)**。
- 每列欄位序：代號, 名稱, 當月營收, 上月營收, **去年當月營收**(index 4), ...（單位：千元）。
  只收第一欄恰為 4 位數字的列（濾表頭/小計）。
- 輸出 shape：`{ "2330": { name, market: "sii"|"otc", industry, series: [{ym:"11509", rev, revLY}] } }`
  `ym` 為民國年月 5 碼；series 由舊到新；缺月直接省略（不補 null/0）。
- 下載時用 `WebClient.DownloadData` 取 bytes 再手動解碼——
  `Invoke-WebRequest` 對無 charset 回應預設 ISO-8859-1，中文會變亂碼。

## 已知資料陷阱（都處理過，改code前先讀）

1. **當月申報可能不齊**：每月 10 日為申報期限，撞假日會順延；缺的公司在月頁上
   整列不存在。index.html 會偵測「個股最新月份 < 全體最大月份」並顯示提示橫幅。
   補救：刪 `scripts/raw/*_<ym>.html` 快取重跑腳本。
2. **來源資料本身有錯**：如 8021 尖點三轉換起日比發行日早一年（櫃買原始資料誤植）。
   原則：**不改原值**，在 UI 明細面板標示「來源資料異常」（index.html 內 anomalies 區塊）。
3. 金融/控股/外國企業（約 33/386 檔）不在月營收報表 → UI 顯示「無資料」等級，屬正常。

## 指標定義（index.html 的 analyse()）

- **滾動 12 月年增 (ttm)**：Σ近12月 rev vs Σ同期 revLY（需 ≥6 組配對才計算）。
- **連續成長 (streak)**：由最新月往回數年增率同號的月數。
- **動能 (momentum)**：近 3 月 YoY 均值 − 全期 YoY 均值；>+1「轉強」、<−1「轉弱」。
  用詞刻意避免「加速/減速」——衰退趨緩時 momentum 為正，「加速」會被誤讀成加速成長。
- 評級：strong（成長中且連增≥6月）/ steady（≥65%月份正成長）/ growing / fading / declining / nodata。

## 設計決策

- **紅漲綠跌**（台股慣例，與美規相反）。色塊與文字分兩組 token：
  `--up/--down` 給圖表色塊（明度拉開，deutan ΔE 20.1 通過 CVD 檢測）、
  `--up-ink/--down-ink` 給文字（WCAG ≥5.4:1）。漲跌永遠同時帶 ▲▼ 與正負號，色彩不單獨承載意義。
- 三態主題（light / dark / system）全以 CSS token 實作；顏色定義不得只出現在
  media query 或 [data-theme] 區塊內。
- 字體：Noto Serif TC（標題）/ Noto Sans TC（內文）/ IBM Plex Mono（數字，tabular-nums）。

## 更新與部署流程

```
powershell -ExecutionPolicy Bypass -File scripts/update-data.ps1
git add data && git commit -m "更新營收資料"
git push origin main main:gh-pages
```

Pages 由 `gh-pages` 分支自動服務（當初推 gh-pages 分支即自動啟用，無 Actions workflow）。
**兩個分支都要推**，只推 main 網站不會更新。
