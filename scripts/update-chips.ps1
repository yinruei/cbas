# update-chips.ps1 — 抓取標的個股的籌碼面（三大法人買賣超）
#
#   data/chips.json   近 5/10/20 個交易日的三大法人買賣超（分外資／投信／自營商）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/update-chips.ps1
#
# 注意：
#   - 本檔必須以 UTF-8 with BOM 儲存（PowerShell 5.1 讀無 BOM 檔會當 ANSI，中文字串會壞）。
#   - 兩市來源不同、欄位排列也不同，各自解析：
#     上市 TWSE  https://www.twse.com.tw/rwd/zh/fund/T86?date=YYYYMMDD&selectType=ALL&response=json
#                欄位用中文表頭對位（表頭順序曾變動過，用名稱比對比用索引安全）。
#     上櫃 TPEX  https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=AL&date=YYYY/MM/DD&response=json
#                tables[0].fields 的「買進股數/賣出股數/買賣超股數」重複出現 7 組，
#                只能靠位置：欄 2-4 外資(不含外資自營)、5-7 外資自營、8-10 外資合計、
#                11-13 投信、14-16 自營(自行)、17-19 自營(避險)、20-22 自營合計、23 三大法人合計。
#   - 單位一律「股」。網頁顯示時換算成「張」(÷1000)。
#   - 非交易日會回空集合，腳本自動略過並往前再找，直到湊滿 N 天。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DAYS = 20         # 抓滿幾個交易日（供 5/10/20 日三個區間累計）
$WINDOWS = @(5, 10, 20)
$MAXBACK = 45      # 最多往回找幾個日曆日（20 交易日約需 28 天，留連假餘裕）

$repo   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repo 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$utf8 = New-Object Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$jss.RecursionLimit = 1024

function Fetch-Text([string]$url) {
  $wc = New-Object Net.WebClient
  $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
  return [Text.Encoding]::UTF8.GetString($wc.DownloadData($url))
}
function ToNum($s) {
  if ($null -eq $s) { return 0 }
  $t = ("$s" -replace '[,\s]', '')
  if ($t -match '^-?\d+(\.\d+)?$') { return [double]$t }
  return 0
}

# code -> @{ name; days = @( @{d; fi; it; dl; tot} ) }
$chips = @{}
function Add-Day($code, $name, $d, $fi, $it, $dl, $tot) {
  if (-not $chips.ContainsKey($code)) { $chips[$code] = @{ name = $name; days = @() } }
  $chips[$code].days += , @{ d = $d; fi = $fi; it = $it; dl = $dl; tot = $tot }
}

$dates = @()
$back = 0
while ($dates.Count -lt $DAYS -and $back -lt $MAXBACK) {
  $day = (Get-Date).AddDays(-$back); $back++
  if ($day.DayOfWeek -eq 'Saturday' -or $day.DayOfWeek -eq 'Sunday') { continue }
  $ymd = $day.ToString('yyyyMMdd')
  $got = $false

  # ---- 上市 TWSE ----
  try {
    $j = $jss.DeserializeObject((Fetch-Text "https://www.twse.com.tw/rwd/zh/fund/T86?date=$ymd&selectType=ALL&response=json"))
    if ($j['stat'] -eq 'OK' -and $j['data']) {
      $f = @($j['fields'])
      $iCode = $f.IndexOf('證券代號'); $iName = $f.IndexOf('證券名稱')
      $iFi   = $f.IndexOf('外陸資買賣超股數(不含外資自營商)')
      $iIt   = $f.IndexOf('投信買賣超股數')
      $iDl   = $f.IndexOf('自營商買賣超股數')
      $iTot  = $f.IndexOf('三大法人買賣超股數')
      if ($iCode -ge 0 -and $iTot -ge 0) {
        foreach ($row in $j['data']) {
          $c = "$($row[$iCode])".Trim()
          if ($c -notmatch '^\d{4}$') { continue }
          Add-Day $c "$($row[$iName])".Trim() $day.ToString('yyyy-MM-dd') `
            (ToNum $row[$iFi]) (ToNum $row[$iIt]) (ToNum $row[$iDl]) (ToNum $row[$iTot])
        }
        $got = $true
      }
    }
  } catch { }

  # ---- 上櫃 TPEX ----
  try {
    $j2 = $jss.DeserializeObject((Fetch-Text "https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=AL&date=$($day.ToString('yyyy/MM/dd'))&response=json"))
    $tb = $j2['tables']
    if ($tb -and $tb[0]['data']) {
      foreach ($row in $tb[0]['data']) {
        $c = "$($row[0])".Trim()
        if ($c -notmatch '^\d{4}$') { continue }
        # 位置固定：4=外資(不含自營)買賣超 13=投信買賣超 22=自營合計買賣超 23=三大法人合計
        Add-Day $c "$($row[1])".Trim() $day.ToString('yyyy-MM-dd') `
          (ToNum $row[4]) (ToNum $row[13]) (ToNum $row[22]) (ToNum $row[23])
      }
      $got = $true
    }
  } catch { }

  if ($got) { $dates += $day.ToString('yyyy-MM-dd'); Write-Host "OK $($day.ToString('yyyy-MM-dd'))" }
  Start-Sleep -Milliseconds 400
}

if ($dates.Count -eq 0) { throw "一個交易日都沒抓到" }
$dates = $dates | Sort-Object

# ---- 彙總：只輸出有可轉債的標的個股 ----
$bondsPath = Join-Path $outDir 'bonds.json'
$want = @{}
if (Test-Path $bondsPath) {
  foreach ($b in $jss.DeserializeObject($utf8.GetString([IO.File]::ReadAllBytes($bondsPath)))) {
    $want["$($b['stockCode'])"] = $true
  }
}

$out = [ordered]@{}
foreach ($code in ($chips.Keys | Sort-Object)) {
  if ($want.Count -and -not $want.ContainsKey($code)) { continue }
  $e = $chips[$code]
  $ser = @($e.days | Sort-Object { $_.d })      # 由舊到新
  $rec = [ordered]@{ name = $e.name; days = $ser.Count }

  # 三個區間各自累計：取序列尾端 N 天（不足 N 天就用全部，並記實際天數）
  foreach ($w in $WINDOWS) {
    $take = [Math]::Min($w, $ser.Count)
    $slice = $ser[($ser.Count - $take)..($ser.Count - 1)]
    $fi = 0.0; $it = 0.0; $dl = 0.0; $tot = 0.0
    foreach ($d in $slice) { $fi += $d.fi; $it += $d.it; $dl += $d.dl; $tot += $d.tot }
    $rec["w$w"] = [ordered]@{
      n   = $take
      fi  = [int64]$fi
      it  = [int64]$it
      dl  = [int64]$dl
      net = [int64]$tot
    }
  }
  # 每日淨額序列（完整 20 日），給走勢圖用
  $rec["series"] = @($ser | ForEach-Object { [ordered]@{ d = $_.d; net = [int64]$_.tot } })
  $out[$code] = $rec
}

$res = [ordered]@{
  asOf    = $dates[-1]
  from    = $dates[0]
  days    = $dates.Count
  windows = $WINDOWS
  unit    = "股"
  source  = "TWSE T86 / TPEX insti dailyTrade"
  rows    = $out
}
$json = $res | ConvertTo-Json -Depth 8 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) })
[IO.File]::WriteAllText((Join-Path $outDir 'chips.json'), $json, $utf8)

Write-Host "`n=== RESULTS ==="
Write-Host "交易日 $($dates[0]) ~ $($dates[-1])（$($dates.Count) 日）"
Write-Host "標的個股 $($out.Count) 檔"
Write-Host "wrote data/chips.json ($((Get-Item (Join-Path $outDir 'chips.json')).Length) bytes)"
foreach ($c in @('6285', '2303', '2221')) {
  if ($out.Contains($c)) {
    $e = $out[$c]
    Write-Host ("spot {0} {1}" -f $c, $e.name)
    foreach ($w in $WINDOWS) {
      $x = $e["w$w"]
      Write-Host ("     近 {0,2} 日({1,2}) 三大法人 {2,13:N0} 股  外資 {3,13:N0}  投信 {4,11:N0}  自營 {5,11:N0}" -f `
        $w, $x.n, $x.net, $x.fi, $x.it, $x.dl)
    }
  }
}
Write-Host "done."
