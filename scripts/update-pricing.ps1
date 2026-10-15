# update-pricing.ps1 — 抓取可轉債評價所需的行情資料
#
#   data/pricing.json   CB 百元價、現股收盤價、現行轉換價（含重設日）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/update-pricing.ps1
#
# 注意：
#   - 本檔必須以 UTF-8 with BOM 儲存（PowerShell 5.1 讀無 BOM 檔會當 ANSI，中文字串會壞）。
#   - 三個來源的日期不一定同步（TWSE 上市收盤常比上櫃晚一天發布），
#     因此各自記錄 asOf，網頁上會顯示；跨日比較會讓折溢價略有偏差。
#   - 轉換價「必須」用 MOPS 月報的現行值：389 檔中有 300 檔已向下重設，
#     用 bonds.json 的發行時轉換價會算錯轉換價值與折溢價。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repo 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$utf8 = New-Object Text.UTF8Encoding($false)
$big5 = [Text.Encoding]::GetEncoding(950)

# PowerShell 5.1 的 ConvertFrom-Json 有 MaxJsonLength 上限，TPEX 日收盤 feed 會超過而丟
# ArgumentException。改用可調上限的 JavaScriptSerializer；回傳 Dictionary，故以 ['key'] 取值。
Add-Type -AssemblyName System.Web.Extensions
$script:jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:jss.MaxJsonLength = [int]::MaxValue
$script:jss.RecursionLimit = 1024
function Parse-Json([string]$s) { return $script:jss.DeserializeObject($s) }

function Fetch-Bytes([string]$url) {
  $wc = New-Object Net.WebClient
  $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
  return $wc.DownloadData($url)
}

# ============================================================
# 1) CB 百元價 — 櫃買每日轉(交)換公司債買賣斷交易行情表 (Big5 CSV)
#    由今天往回找最近一個有檔案的交易日
# ============================================================
Write-Host "=== CB 行情 ==="
$quote = @{}
$quoteDate = $null
for ($back = 0; $back -lt 12; $back++) {
  $d = (Get-Date).AddDays(-$back)
  $ymd = $d.ToString('yyyyMMdd')
  $url = "https://www.tpex.org.tw/storage/bond_zone/tradeinfo/cb/$($d.ToString('yyyy'))/$($d.ToString('yyyyMM'))/RSta0113.$ymd-C.csv"
  try {
    $csv = $big5.GetString((Fetch-Bytes $url))
  } catch { continue }
  foreach ($line in ($csv -split "`r?`n")) {
    if (-not $line.StartsWith('BODY,')) { continue }
    $c = [regex]::Matches($line.Substring(5), '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value.Trim() }
    if ($c.Count -lt 12 -or $c[0] -notmatch '^\d{5}$') { continue }
    $close = ($c[3] -replace ',', '').Trim()
    if ($close -notmatch '^\d+(\.\d+)?$') { continue }
    if ($quote.ContainsKey($c[0])) { continue }      # 同一檔有等價/議價兩列，取先出現的等價
    $chg = ($c[4] -replace '[, ]', '')
    $vol = ($c[9] -replace ',', '').Trim()
    $quote[$c[0]] = [ordered]@{
      close  = [double]$close
      change = $(if ($chg -match '^[+-]?\d+(\.\d+)?$') { [double]$chg } else { $null })
      volume = $(if ($vol -match '^\d+$') { [int]$vol } else { 0 })
      mode   = $c[2]
    }
  }
  if ($quote.Count) { $quoteDate = $d.ToString('yyyy-MM-dd'); break }
}
if (-not $quoteDate) { throw "找不到任何 CB 行情檔（往回 12 天）" }
Write-Host "CB 行情 $quoteDate : $($quote.Count) 檔有收盤價"

# ============================================================
# 2) 現行轉換價 — MOPS 轉換公司債轉換變動情形一覽表 (Big5 HTML)
#    欄序：公司代號<br>名稱 | 證券代號<br>簡稱 | 買回張數 | 轉換張數 | 轉換價格 | 重設日期 | 轉換普通股
# ============================================================
Write-Host "`n=== 現行轉換價 ==="
$conv = @{}
$convMonth = $null
for ($back = 0; $back -lt 4; $back++) {
  $d = (Get-Date).AddMonths(-$back)
  $url = "https://mopsov.twse.com.tw/nas/t120/CBTRN$($d.ToString('yyyyMM')).htm"
  try { $htm = $big5.GetString((Fetch-Bytes $url)) } catch { continue }
  foreach ($rm in [regex]::Matches($htm, '(?is)<tr[^>]*>(.*?)</tr>')) {
    $cells = @()
    foreach ($cm in [regex]::Matches($rm.Groups[1].Value, '(?is)<t[dh][^>]*>(.*?)</t[dh]>')) {
      $v = $cm.Groups[1].Value -replace '(?i)<br\s*/?>', "`t"        # <br> 分隔代號與名稱，不可與標籤一起剝除
      $cells += ([regex]::Replace($v, '(?is)<[^>]+>', '') -replace '&nbsp;', ' ').Trim()
    }
    if ($cells.Count -lt 6) { continue }
    $bc = ($cells[1] -split "`t")[0].Trim()
    if ($bc -notmatch '^\d{5}$') { continue }
    $p = ($cells[4] -replace ',', '').Trim()
    if ($p -notmatch '^\d+(\.\d+)?$') { continue }
    $conv[$bc] = [ordered]@{ price = [double]$p; reset = $cells[5].Trim() }
  }
  if ($conv.Count) { $convMonth = $d.ToString('yyyy-MM'); break }
}
if (-not $convMonth) { throw "找不到 CBTRN 轉換價月報（往回 4 個月）" }
Write-Host "轉換價 $convMonth : $($conv.Count) 檔"

# ============================================================
# 3) 現股收盤價 — 上市 TWSE / 上櫃 TPEX
# ============================================================
Write-Host "`n=== 現股收盤 ==="
$stock = @{}
$stockSrc = @{}      # 代號 -> 該檔現股收盤日期
$stockDate = @{}

$tw = Parse-Json $utf8.GetString((Fetch-Bytes 'https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL'))
foreach ($r in $tw) {
  $c = "$($r['Code'])"; $cp = "$($r['ClosingPrice'])"
  if ($c -match '^\d{4}$' -and $cp -match '^\d+(\.\d+)?$') { $stock[$c] = [double]$cp }
}
if ($tw.Count) { $d0 = "$($tw[0]['Date'])"; $stockDate['sii'] = "$([int]$d0.Substring(0,3) + 1911)-$($d0.Substring(3,2))-$($d0.Substring(5,2))" }
foreach ($k in @($stock.Keys)) { $stockSrc[$k] = $stockDate['sii'] }
Write-Host "上市 $($stockDate['sii']) : $($stock.Count) 檔"

$n1 = $stock.Count
$otcCodes = @()
$tp = Parse-Json $utf8.GetString((Fetch-Bytes 'https://www.tpex.org.tw/openapi/v1/tpex_mainboard_daily_close_quotes'))
foreach ($r in $tp) {
  $c = "$($r['SecuritiesCompanyCode'])"; $cl = "$($r['Close'])"
  if ($c -match '^\d{4}$' -and $cl -match '^\d+(\.\d+)?$') { $stock[$c] = [double]$cl; $otcCodes += $c }
}
if ($tp.Count) { $d0 = "$($tp[0]['Date'])"; $stockDate['otc'] = "$([int]$d0.Substring(0,3) + 1911)-$($d0.Substring(3,2))-$($d0.Substring(5,2))" }
foreach ($k in $otcCodes) { $stockSrc[$k] = $stockDate['otc'] }
Write-Host "上櫃 $($stockDate['otc']) : +$($stock.Count - $n1) 檔，合計 $($stock.Count)"

# ============================================================
# 4) 併入 bonds.json 並輸出
# ============================================================
$bonds = Parse-Json $utf8.GetString([IO.File]::ReadAllBytes((Join-Path $outDir 'bonds.json')))
$rows = [ordered]@{}
$nQ = 0; $nC = 0; $nS = 0
foreach ($b in $bonds) {
  $bc = "$($b['bondCode'])" 
  $e = [ordered]@{}
  if ($quote.ContainsKey($bc))  { $e.cbClose = $quote[$bc].close; $e.cbChange = $quote[$bc].change; $e.cbVolume = $quote[$bc].volume; $nQ++ }
  if ($conv.ContainsKey($bc))   { $e.convPrice = $conv[$bc].price; $e.convReset = $conv[$bc].reset; $nC++ }
  if ($stock.ContainsKey("$($b['stockCode'])")) {
    $e.stockPrice = $stock["$($b['stockCode'])"]
    $e.stockDate  = $stockSrc["$($b['stockCode'])"]          # 上市/上櫃的收盤日期可能不同，逐檔記錄
    $nS++
  }
  if ($e.Count) { $rows[$bc] = $e }
}

$out = [ordered]@{
  asOf = [ordered]@{ cbQuote = $quoteDate; convPrice = $convMonth; stockSii = $stockDate['sii']; stockOtc = $stockDate['otc'] }
  rows = $rows
}
$json = $out | ConvertTo-Json -Depth 6 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
[IO.File]::WriteAllText((Join-Path $outDir 'pricing.json'), $json, $utf8)

Write-Host "`n=== RESULTS ==="
Write-Host "bonds: $($bonds.Count) ; 有行情 $nQ ; 有現行轉換價 $nC ; 有現股價 $nS"
Write-Host "wrote data/pricing.json ($((Get-Item (Join-Path $outDir 'pricing.json')).Length) bytes)"

# 抽查：列出三檔同時具備三項資料者，印出折溢價供人工核對
$k = 0
foreach ($b in $bonds) {
  if ($k -ge 3) { break }
  $r = $rows["$($b['bondCode'])"]
  if (-not $r -or -not $r.cbClose -or -not $r.convPrice -or -not $r.stockPrice) { continue }
  $cv = 100.0 / $r.convPrice * $r.stockPrice
  $prem = ($r.cbClose - $cv) / $cv * 100
  Write-Host ("spot {0,-12} 百元價={1,7:N2} 現股={2,8:N2} 轉換價={3,8:N2} 轉換價值={4,7:N2} 折溢價={5,7:N2}% 現股日={6}" -f `
    "$($b['bondName'])", $r.cbClose, $r.stockPrice, $r.convPrice, $cv, $prem, $r.stockDate)
  $k++
}
Write-Host "done. 更新後: git add data && git commit && git push origin main main:gh-pages"
