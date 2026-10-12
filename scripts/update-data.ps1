# update-data.ps1 — 重新抓取 data/ 下的兩個資料檔
#
#   data/bonds.json            可轉債清單（櫃買中心 OpenAPI bond_ISSBD5_data）
#   data/monthly_revenue.json  上市＋上櫃近 12 個月營收（MOPS t21sc03 月報表，Big5）
#
# 用法（在 repo 根目錄或任何位置皆可）：
#   powershell -ExecutionPolicy Bypass -File scripts/update-data.ps1
#
# 注意：
#   - 本檔必須以 UTF-8 with BOM 儲存（PowerShell 5.1 讀無 BOM 檔會當 ANSI，中文字串會壞）。
#   - 月營收頁快取在 scripts/raw/（已列入 .gitignore）。某月資料未齊（例如申報
#     期限撞連假）想強制重抓，刪掉 scripts/raw/ 對應的 *_<ym>.html 再跑一次。
#   - 月份視窗自動取「上個月」往回 12 個月；每月 10 日後上個月資料才齊全。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repo 'data'
$raw    = Join-Path $PSScriptRoot 'raw'
foreach ($d in @($outDir, $raw)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

$utf8 = New-Object Text.UTF8Encoding($false)
$big5 = [Text.Encoding]::GetEncoding(950)

function Fetch-Bytes([string]$url) {
  $wc = New-Object Net.WebClient
  $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
  return $wc.DownloadData($url)
}

# ============================================================
# 1) 可轉債清單 bonds.json
# ============================================================
Write-Host "=== bonds.json ==="
$bytes = Fetch-Bytes 'https://www.tpex.org.tw/openapi/v1/bond_ISSBD5_data'
$issbd = $utf8.GetString($bytes) | ConvertFrom-Json
Write-Host "ISSBD5 records: $($issbd.Count)"

function Clean([string]$s) { if (-not $s) { return '' }; return ($s -replace '&#\d+;', '').Trim() }
function D([string]$d) { if ($d -and $d.Length -eq 8) { return "$($d.Substring(0,4))-$($d.Substring(4,2))-$($d.Substring(6,2))" }; return '' }

# 僅留公開發行 (OfferingMethod=7) 且 4 碼股票代號 — 其餘為私募或特殊代號
$pub = @($issbd | Where-Object { $_.OfferingMethod -eq '7' -and $_.IssuerCode -match '^\d{4}$' })
Write-Host "public offerings kept: $($pub.Count) (dropped $($issbd.Count - $pub.Count) private placements)"

$bondsOut = $pub | ForEach-Object {
  [pscustomobject][ordered]@{
    stockCode   = $_.IssuerCode
    issuer      = Clean $_.IssuerName
    bondCode    = $_.BondCode
    bondName    = Clean $_.ShortName
    series      = $_.SeriesNumber
    issueDate   = D $_.IssueDate
    listingDate = D $_.ListingDate
    maturity    = D $_.MaturityDate
    tenorYear   = [int]$_.TenorYear
    guaranteed  = $(switch ($_.Guaranteed) { '1' { '有擔保' } '2' { '無擔保' } default { '其他' } })
    couponRate  = [double]$_.CouponRate
    issueAmt    = [double]$_.IssueAmount
    outAmt      = [double]$_.OutstandingAmount
    convPrice   = $(if ($_.'Conversion/ExchangePriceAtIssuance') { [double]$_.'Conversion/ExchangePriceAtIssuance' } else { $null })
    convStart   = D $_.'Conversion/ExchangePeriodStartDate'
    convEnd     = D $_.'Conversion/ExchangePeriodEndDate'
    putDate     = D $_.PutOptionDate
    putPrice    = $(if ($_.PutOptionPrice) { [double]$_.PutOptionPrice } else { $null })
  }
} | Sort-Object listingDate -Descending

$json = $bondsOut | ConvertTo-Json -Depth 3 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
[IO.File]::WriteAllText((Join-Path $outDir 'bonds.json'), $json, $utf8)
Write-Host "wrote data/bonds.json ($($bondsOut.Count) bonds)`n"

# ============================================================
# 2) 月營收 monthly_revenue.json — 近 12 個月（至上個月止）
# ============================================================
Write-Host "=== monthly_revenue.json ==="
$months = @()   # @(民國年, 月)，由舊到新
$cursor = (Get-Date).AddMonths(-13)   # 迴圈先 +1，故 12 次落在 -12..-1 個月（最新=上個月）
for ($i = 0; $i -lt 12; $i++) {
  $cursor = $cursor.AddMonths(1)
  $months += , @(($cursor.Year - 1911), $cursor.Month)   # 括號必要：PS 逗號優先級高於減法
}
Write-Host ("window: {0}{1:D2} .. {2}{3:D2}" -f $months[0][0], $months[0][1], $months[11][0], $months[11][1])

$ok = 0; $failed = @()
foreach ($mk in @('sii', 'otc')) {
  foreach ($mm in $months) {
    $y = $mm[0]; $m = $mm[1]
    $ym = '{0}{1:D2}' -f $y, $m
    $file = Join-Path $raw "$mk`_$ym.html"
    if (Test-Path $file) { $ok++; continue }
    $url = "https://mopsov.twse.com.tw/nas/t21/$mk/t21sc03_$($y)_$($m)_0.html"
    $done = $false
    for ($try = 1; $try -le 3; $try++) {
      try {
        $b = Fetch-Bytes $url
        if ($b.Length -lt 2000) { throw "too small: $($b.Length)" }
        [IO.File]::WriteAllBytes($file, $b)
        $done = $true; break
      } catch {
        Write-Host "  retry $try $mk $ym : $($_.Exception.Message)"
        Start-Sleep -Milliseconds 1500
      }
    }
    if ($done) { $ok++; Write-Host "OK $mk $ym" } else { $failed += "$mk $ym -> $url" }
    Start-Sleep -Milliseconds 450
  }
}
Write-Host "fetch: ok=$ok / 24"
$failed | ForEach-Object { Write-Host "FAILED: $_" }

# ---- 解析（Big5；欄位：代號,名稱,當月營收,上月營收,去年當月營收,...）----
$data = @{}
$cellRx = [regex]'(?is)<t[dh][^>]*>(.*?)</t[dh]>'
$rowRx  = [regex]'(?is)<tr[^>]*>(.*?)</tr>'

foreach ($mk in @('sii', 'otc')) {
  foreach ($mm in $months) {
    $ym = '{0}{1:D2}' -f $mm[0], $mm[1]
    $file = Join-Path $raw "$mk`_$ym.html"
    if (-not (Test-Path $file)) { continue }
    $html = $big5.GetString([IO.File]::ReadAllBytes($file))
    $nrow = 0
    foreach ($rm in $rowRx.Matches($html)) {
      $cells = @()
      foreach ($cm in $cellRx.Matches($rm.Groups[1].Value)) {
        $t = [regex]::Replace($cm.Groups[1].Value, '(?is)<[^>]+>', '') -replace '&nbsp;', ' '
        $cells += $t.Trim()
      }
      if ($cells.Count -lt 3) { continue }
      $code = $cells[0]
      if ($code -notmatch '^\d{4}$') { continue }   # 濾掉表頭與小計列
      $revS = ($cells[2] -replace ',', '').Trim()
      if ($revS -notmatch '^-?\d+(\.\d+)?$') { continue }
      $revLY = $null
      if ($cells.Count -ge 5) {
        $lyS = ($cells[4] -replace ',', '').Trim()
        if ($lyS -match '^-?\d+(\.\d+)?$') { $revLY = [double]$lyS }
      }
      if (-not $data.ContainsKey($code)) {
        $data[$code] = @{ name = $cells[1]; market = $mk; industry = ''; series = @{}; ly = @{} }
      }
      $e = $data[$code]
      $e.name = $cells[1]
      $e.market = $mk                 # 月份由舊到新迭代，最後寫入者即最新市場別
      $e.series[$ym] = [double]$revS
      $e.ly[$ym] = $revLY
      $nrow++
    }
    Write-Host "parsed $mk $ym : $nrow rows"
  }
}

# ---- 產業別（兩個 OpenAPI 即時抓）----
$indCount = 0
foreach ($u in @('https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap05_O',
                 'https://openapi.twse.com.tw/v1/opendata/t187ap05_L')) {
  try {
    $j = $utf8.GetString((Fetch-Bytes $u)) | ConvertFrom-Json
    $codeProp = $null; $indProp = $null
    foreach ($p in $j[0].PSObject.Properties.Name) {
      if ($p -eq '公司代號') { $codeProp = $p }
      if ($p -like '*產業*') { $indProp = $p }
    }
    if (-not $codeProp -or -not $indProp) { continue }
    foreach ($r in $j) {
      $c = "$($r.$codeProp)".Trim()
      if ($data.ContainsKey($c)) {
        $ind = "$($r.$indProp)".Trim()
        if ($ind -ne '') { $data[$c].industry = $ind; $indCount++ }
      }
    }
  } catch { Write-Host "industry feed failed: $u — $($_.Exception.Message)" }
}
Write-Host "industry assigned: $indCount"

# ---- 輸出 ----
$out = [ordered]@{}
foreach ($code in ($data.Keys | Sort-Object)) {
  $e = $data[$code]
  $series = @()
  foreach ($ym in ($e.series.Keys | Sort-Object)) {
    $v = $e.series[$ym]
    $num = if ($v -eq [math]::Floor($v)) { [int64]$v } else { $v }
    $lv = $e.ly[$ym]; $lnum = $null
    if ($null -ne $lv) { $lnum = if ($lv -eq [math]::Floor($lv)) { [int64]$lv } else { $lv } }
    $series += [ordered]@{ ym = $ym; rev = $num; revLY = $lnum }
  }
  $out[$code] = [ordered]@{ name = $e.name; market = $e.market; industry = $e.industry; series = $series }
}

$json = $out | ConvertTo-Json -Depth 6 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
[IO.File]::WriteAllText((Join-Path $outDir 'monthly_revenue.json'), $json, $utf8)

$full = 0
foreach ($k in $out.Keys) { if ($out[$k].series.Count -eq 12) { $full++ } }
Write-Host "`n=== RESULTS ==="
Write-Host "companies: $($out.Count) ; full 12-month: $full"
foreach ($c in @('2330', '2303')) {   # 抽查：名稱不得是亂碼、YoY 要合理
  if ($out.Contains($c)) {
    $e = $out[$c]; $s = $e.series[-1]
    $yoy = if ($s.revLY) { '{0:N1}%' -f ((($s.rev - $s.revLY) / $s.revLY) * 100) } else { 'n/a' }
    Write-Host "spot $c $($e.name) [$($e.market)] latest=$($s.ym) rev=$('{0:N0}' -f $s.rev) YoY=$yoy"
  }
}
Write-Host "done. 更新後記得: git add data && git commit && git push origin main main:gh-pages"
