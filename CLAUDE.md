# CBAS — 可轉債營收動能儀表板

單頁靜態網站：台灣上櫃轉（交）換公司債清單 × 標的個股近 12 個月營收趨勢。
部署於 GitHub Pages：https://yinruei.github.io/cbas/ （repo: yinruei/cbas）

## 架構

- `index.html` — 全部的 UI 與邏輯（無建置步驟、無外部 JS 相依；字型用 Google Fonts）。
  以 `fetch("data/*.json")` 載入資料，所以**必須經 HTTP 服務**開啟（`python -m http.server`），
  直接 file:// 開會因 CORS 載不到資料。
- `data/bonds.json` — 可轉債清單（約 389 筆）。
- `data/monthly_revenue.json` — 上市＋上櫃約 1,857 家公司的月營收序列。
- `data/pricing.json` — CB 百元價、現股收盤、現行轉換價（評價用）。
- `data/cbas_quotes.json` — **人工維護**的 CBAS 權利金報價，不由腳本覆寫。
- `scripts/update-pricing.ps1` — 重抓 pricing.json。
- `scripts/update-data.ps1` — 重抓前兩檔。Windows PowerShell 5.1 可跑；
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

### pricing.json ← 三個來源
- **CB 百元價**：櫃買每日行情 CSV
  `https://www.tpex.org.tw/storage/bond_zone/tradeinfo/cb/{YYYY}/{YYYYMM}/RSta0113.{YYYYMMDD}-C.csv`
  Big5；列首為 `BODY,`；欄序 代號,名稱,交易,收市,漲跌,開市,最高,最低,筆數,單位,金額,...
  同一檔有「等價」「議價」兩列，取先出現者。約 200/389 檔當日有成交。
- **現行轉換價**：MOPS `https://mopsov.twse.com.tw/nas/t120/CBTRN{YYYYMM}.htm`
  Big5；7 欄，代號與名稱用 `<br>` 擠在同一格——**剝標籤前要先把 `<br>` 換成分隔符**，
  否則 `11011台泥一永` 連在一起取不到代號。轉換價在 index 4、重設日在 index 5。
- **現股收盤**：TWSE `exchangeReport/STOCK_DAY_ALL`＋TPEX `tpex_mainboard_daily_close_quotes`。
  **PS 5.1 的 `ConvertFrom-Json` 有 MaxJsonLength 上限，TPEX feed 會超過而丟 ArgumentException**，
  故改用 `JavaScriptSerializer`（`MaxJsonLength = [int]::MaxValue`），回傳 Dictionary 要用 `['key']` 取值。

## 已知資料陷阱（都處理過，改code前先讀）

1. **當月申報可能不齊**：每月 10 日為申報期限，撞假日會順延；缺的公司在月頁上
   整列不存在。index.html 會偵測「個股最新月份 < 全體最大月份」並顯示提示橫幅。
   補救：刪 `scripts/raw/*_<ym>.html` 快取重跑腳本。
2. **來源資料本身有錯**：如 8021 尖點三轉換起日比發行日早一年（櫃買原始資料誤植）。
   原則：**不改原值**，在 UI 明細面板標示「來源資料異常」（index.html 內 anomalies 區塊）。
3. 金融/控股/外國企業（約 33/389 檔）不在月營收報表 → UI 顯示「無資料」等級，屬正常。
4. **轉換價會重設**：389 檔中 300 檔的現行轉換價已與發行時不同（除權息、現增向下調整）。
   bonds.json 的 `convPrice` 是**發行時**的值，算轉換價值與折溢價**必須**改用 pricing.json 的現行值。
5. **上市現股收盤比 CB 行情晚一天**：TWSE 的 API 盤後才更新，跨日比價會讓折溢價失真。
   pricing.json 逐檔記錄 `stockDate`，UI 在落後的列標 ⚠ 並於抬頭顯示「部分現股 <日期>」。
6. 可轉債流動性低，當日無成交即無收盤價（約 190/389 檔無報價），評價欄位顯示「—」屬正常。

## 指標定義（index.html 的 analyse()）

- **滾動 12 月年增 (ttm)**：Σ近12月 rev vs Σ同期 revLY（需 ≥6 組配對才計算）。
- **連續成長 (streak)**：由最新月往回數年增率同號的月數。
- **動能 (momentum)**：近 3 月 YoY 均值 − 全期 YoY 均值；>+1「轉強」、<−1「轉弱」。
  用詞刻意避免「加速/減速」——衰退趨緩時 momentum 為正，「加速」會被誤讀成加速成長。
- 評級：strong（成長中且連增≥6月）/ steady（≥65%月份正成長）/ growing / fading / declining / nodata。

### cbas_quotes.json ← 人工維護（無公開來源）
- CBAS（可轉債資產交換）權利金由各券商自行報價，**沒有公開行情可抓**。
  櫃買唯一相關的 `tpex_dpsp_monthly_CBmcs007` 只有各券商承作餘額，不含報價。
- 格式：`{ asOf, source, parFloor, quotes: { "<債券代號>": <百元報價> } }`
- 有填的欄位標「券商報價」；未填者以 `CB市價 − parFloor(100)` 估算並標「估算」。
- **此檔不會被 update-*.ps1 覆寫**，更新行情不會動到你填的報價。

## 評價公式（index.html 的 valuation()）

- 面額 10 萬／張，報價為百元價。**CB 市價 ＝ 百元價 × 1000**
- **轉換價值 ＝ (100 ÷ 現行轉換價) × 現股市價**（百元基準，與百元價同單位才能比較）
- **折溢價 ＝ (百元價 − 轉換價值) ÷ 轉換價值**
- **轉換率 ＝ 100,000 ÷ 現行轉換價**（每張可轉股數）
- **折現率 ＝ (賣回價 ÷ 百元價)^(1/剩餘年數) − 1**，零息假設（台灣可轉債票面利率幾乎都是 0%）
- **選擇權到期日** 取轉換權迄日 `convEnd`
- **百元報價（CBAS 權利金）**：券商持債券部位、投資人只買選擇權那段所付的錢。
  有人工報價用真值，否則 `CB市價 − 債底(100)` 估算。估算不含券商資金成本與價差，
  與實際報價會差數個百分點——只能用來排序初篩，不可當成交價。
- 折溢價**不套用紅漲綠跌**：它是「貴/便宜」不是「漲/跌」，與營收漲跌共用紅綠會誤導。
  折價用強調色 `--accent-deep` 並加「折價」標籤，溢價用一般文字色。

## 設計決策

- **紅漲綠跌**（台股慣例，與美規相反）。色塊與文字分兩組 token：
  `--up/--down` 給圖表色塊（明度拉開，deutan ΔE 20.1 通過 CVD 檢測）、
  `--up-ink/--down-ink` 給文字（WCAG ≥5.4:1）。漲跌永遠同時帶 ▲▼ 與正負號，色彩不單獨承載意義。
- 三態主題（light / dark / system）全以 CSS token 實作；顏色定義不得只出現在
  media query 或 [data-theme] 區塊內。
- 字體：Noto Serif TC（標題）/ Noto Sans TC（內文）/ IBM Plex Mono（數字，tabular-nums）。

## 更新與部署流程

```
powershell -ExecutionPolicy Bypass -File scripts/update-data.ps1     # 營收＋債券清單（月更）
powershell -ExecutionPolicy Bypass -File scripts/update-pricing.ps1  # 行情＋轉換價（日更）
git add data && git commit -m "更新資料"
git push origin main main:gh-pages
```

Pages 由 `gh-pages` 分支自動服務（當初推 gh-pages 分支即自動啟用，無 Actions workflow）。
**兩個分支都要推**，只推 main 網站不會更新。
