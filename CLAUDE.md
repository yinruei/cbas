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
- `data/cbas_quotes.json` — CBAS 權利金報價，由 `scripts/import_quotes.py` 從券商報價單匯入。
- `scripts/import_quotes.py` — 讀券商 .xlsx 報價單產生上檔（需 `pip install openpyxl`）。
- `data/chips.json` — 標的個股近 5/10/20 個交易日三大法人買賣超（籌碼面）。
- `scripts/update-pricing.ps1` — 重抓 pricing.json。
- `scripts/update-chips.ps1` — 重抓 chips.json。
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

### chips.json ← 三大法人買賣超（兩市來源不同）
- 上市 TWSE：`https://www.twse.com.tw/rwd/zh/fund/T86?date=YYYYMMDD&selectType=ALL&response=json`
  （OpenAPI 的 `/v1/fund/T86` 回 HTML 不可用）。欄位用**中文表頭名稱**對位，不要用索引。
- 上櫃 TPEX：`https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=AL&date=YYYY/MM/DD&response=json`
  `tables[0].fields` 的「買進/賣出/買賣超股數」重複 7 組，**只能靠位置**：
  4=外資(不含自營)、13=投信、22=自營合計、23=三大法人合計。
- 單位是**股**，UI 顯示時 ÷1000 換成張。非交易日回空集合，腳本自動往前找滿 20 天。
- 只輸出 bonds.json 裡有的標的個股（約 309 檔）。
- 輸出 shape：`{ "6285": { name, days, w5:{n,fi,it,dl,net}, w10:{...}, w20:{...}, series:[{d,net}] } }`
  三個區間都預先算好，UI 的 `chipWin` 只是切換要顯示哪一個，不重抓資料。
- **抓 20 個交易日約 40 次請求、需一兩分鐘**，每次間隔 400ms 以免被擋。

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

### cbas_quotes.json ← 券商報價單 .xlsx（無公開來源）
- CBAS 權利金由各券商自行報價，**沒有公開行情可抓**。櫃買的
  `tpex_dpsp_monthly_CBmcs007` 只有承作餘額，不含報價。
- 來源：元大證券「轉換公司債資產交換選擇權報價表-債券部」.xlsx，工作表 `報價單`。
  第 2 列 B 欄 = 報價日；第 4 列表頭；第 6 列起資料；第 86 列後是「註：」說明，需濾掉。
- 欄序（0-based）：0 名稱 1 代碼 2 擔保/TCRI 3 **權利金(佰元報價)** 4 選擇權到期日
  5 賣回價格(A) 6 賣回日期(B) 7 剩餘年期 8 **折現率(C)** 9 權利金參考價
  10 現股參考價 11 轉換價格 12 CB轉換價值 13 CB參考價 14 溢(折)價%
- **代號為 5~6 碼**：第 10 次以後發行者是 6 碼（岳豐十 = 622010）。只收 5 碼會漏抓。
- 重跑 `python scripts/import_quotes.py <xlsx>` 即覆寫；update-*.ps1 不會動此檔。

## 評價公式（index.html 的 valuation()）

- 面額 10 萬／張，報價為百元價。**CB 市價 ＝ 百元價 × 1000**
- **轉換價值 ＝ (100 ÷ 現行轉換價) × 現股市價**（百元基準，與百元價同單位才能比較）
- **折溢價 ＝ (百元價 − 轉換價值) ÷ 轉換價值**
- **轉換率 ＝ 100,000 ÷ 現行轉換價**（每張可轉股數）
- **折現率 ＝ (賣回價 ÷ 百元價)^(1/剩餘年數) − 1**，零息假設（台灣可轉債票面利率幾乎都是 0%）
- **選擇權到期日** 取轉換權迄日 `convEnd`
- **百元報價（CBAS 權利金）**：只取券商報價單的「權利金(佰元報價)」。
  **券商未報價者一律留空，不以 `CB市價 − 債底` 反推估算**——使用者明確要求過：
  估算值與實際報價可差數個百分點，顯示出來會被誤當成可交易的數字。
  目前 389 檔中有 78 檔有報價。
- **實際權利金(一張)** ＝ (佰元報價 + (CB買進成交價 − 100)) × 1000（報價單註九）。
- **折現率(C)** 是**券商訂價用的資金成本**（3%~4.75%），只有報價單有、無法自行推算。
  **不要跟「賣回殖利率」混為一談**——後者是以現價持有至賣回的年化報酬，多為負值。
  兩者在 UI 是分開的兩個欄位。
- **賣回條件**：bonds.json 有 128 檔的 putDate/putPrice 是空的，其中 40 檔可由
  券商報價單補回；UI 會標「取自券商報價單」。
- 折溢價**不套用紅漲綠跌**：它是「貴/便宜」不是「漲/跌」，與營收漲跌共用紅綠會誤導。
  折價用強調色 `--accent-deep` 並加「折價」標籤，溢價用一般文字色。

## 散佈圖（折價 × 成長 × 籌碼）

評價檢視上方的散佈圖，把原本分散在兩個檢視的資訊疊在一起：
x=折溢價（左為折價）、y=滾動 12 月年增、點色=籌碼（紅買超／綠賣超／灰無資料）、
空心=券商未報價。左上淡藍區即三者兼具的標的。

- **座標軸必須裁切**：折溢價中位 ~20%、最大 ~170%；年增最大 ~900%。
  用 p95/p97 當上界會把折價區壓成左邊一條細縫，而那正是要看的地方。
  現用 x→p85、y→p90，並保證負值區至少佔得到版面；超出者畫在邊界、透明度降到 .45。
- 點色沿用紅漲綠跌，與營收欄位語意一致（紅＝正面），不是另一套配色。
  灰色是「無資料」不是中性值。圖例以 ▲▼ 加文字說明，顏色不單獨承載意義。
- 圖上方的 5/10/20 日切換會同時改變點色與表格的籌碼欄；切換時要呼叫 `build()`
  重算 rowsData（籌碼值變了），只呼叫 `applyFilters()` 不會更新。
- 同一檔在不同區間可能方向相反（例：嘉晶六 近5日 −2,229 張、近20日 +27,276 張），
  這正是提供三個區間的理由——只看單一區間會誤判。

## 設計決策

- **紅漲綠跌**（台股慣例，與美規相反）。色塊與文字分兩組 token：
  `--up/--down` 給圖表色塊（明度拉開，deutan ΔE 20.1 通過 CVD 檢測）、
  `--up-ink/--down-ink` 給文字（WCAG ≥5.4:1）。漲跌永遠同時帶 ▲▼ 與正負號，色彩不單獨承載意義。
- 三態主題（light / dark / system）全以 CSS token 實作；顏色定義不得只出現在
  media query 或 [data-theme] 區塊內。
- 字體以 CSS 變數集中管理，換字型只改 `:root` 的三行即可：
  `--f-head` Chiron Sung HK（昭源宋體，標題）/ `--f-body` Noto Sans TC（內文）/
  `--f-mono` Geist Mono（數字，0 有斜線、0O 與 1lI 不混淆，配 tabular-nums）。
  **改這三個變數時注意不要讓 fallback 參照到變數自己**（曾因正規替換造成
  `--f-head: "Chiron Sung HK", var(--f-head)` 循環參照，整頁字型失效）。
- 內文基準 16px。中文在 11px 以下的密集表格會難讀，小字標籤最低用到 11.5px。

## 更新與部署流程

**使用者的節奏是每週更新一次**（非每日），所以三個來源一次全跑：

```
powershell -ExecutionPolicy Bypass -File scripts/update-data.ps1     # 營收＋債券清單
powershell -ExecutionPolicy Bypass -File scripts/update-pricing.ps1  # CB行情＋現股＋轉換價
powershell -ExecutionPolicy Bypass -File scripts/update-chips.ps1    # 三大法人買賣超（近5日）
python scripts/import_quotes.py "<當週券商報價單.xlsx>"               # CBAS 權利金
git add data && git commit -m "更新資料"
git push origin main main:gh-pages
```

每週跑的注意事項：
- 月營收每月 10 日後才會有上個月的新資料；其餘週次跑起來內容不變，屬正常。
- 券商報價單是使用者自行取得的 .xlsx，路徑每週不同，要先問使用者檔案在哪。
- 行情日期若落在週末，`update-pricing.ps1` 會自動往回找最近的交易日。

Pages 由 `gh-pages` 分支自動服務（當初推 gh-pages 分支即自動啟用，無 Actions workflow）。
**兩個分支都要推**，只推 main 網站不會更新。
