$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$STATE = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $STATE)) { New-Item -ItemType Directory -Path $STATE -Force | Out-Null }
$OUT = Join-Path $STATE 'extra_metrics.json'

# Defaults: every field is pre-initialized so the final JSON is ALWAYS written,
# even if a probe below fails or hangs. No single step can block the write.

# ---- GPU (Radeon 890M) ----
$gpuName = $null; $gpuPct = $null; $gpuAvail = $false
try {
  $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Remote|Basic|Microsoft' } | Select-Object -First 1
  if ($g) { $gpuName = $g.Name }
  $c = Get-Counter '\GPU Engine(*)\Utilization Percentage' -MaxSamples 1 -ErrorAction Stop
  $vals = $c.CounterSamples | Where-Object { $_.InstanceName -notmatch '^engtype_0' } | Select-Object -ExpandProperty CookedValue
  if ($vals.Count -gt 0) { $gpuPct = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1); $gpuAvail = $true }
} catch {}

# ---- NPU (Ryzen AI XDNA) - counter usually absent; degrade gracefully ----
$npuName = 'Ryzen AI NPU (XDNA)'; $npuPct = $null; $npuAvail = $false
try {
  $n = Get-Counter '\NPU Engine(*)\Utilization Percentage' -MaxSamples 1 -ErrorAction Stop
  $nvals = $n.CounterSamples | Select-Object -ExpandProperty CookedValue
  if ($nvals.Count -gt 0) { $npuPct = [math]::Round(($nvals | Measure-Object -Maximum).Maximum, 1); $npuAvail = $true }
} catch {}

# ---- Memory: total from ComputerSystem; available from Available Bytes counter (= Task Manager "available") ----
$memTotal = $null; $memFree = $null; $memAvail = $null; $memStandby = $null; $memCached = $null; $memPct = $null
try {
  $cs = Get-CimInstance Win32_ComputerSystem
  if ($cs -and $cs.TotalPhysicalMemory) { $memTotal = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }
} catch {}
try { $memAvail = [math]::Round((Get-Counter '\Memory\Available Bytes' -MaxSamples 1).CounterSamples.CookedValue / 1GB, 2) } catch {}
try { $memStandby = [math]::Round((Get-Counter '\Memory\Standby Cache Reserve Bytes' -MaxSamples 1).CounterSamples.CookedValue / 1GB, 2) } catch {}
try { $memCached = [math]::Round((Get-Counter '\Memory\Cache Bytes' -MaxSamples 1).CounterSamples.CookedValue / 1GB, 2) } catch {}
try { $memFree = [math]::Round((Get-Counter '\Memory\Free & Zero Page List Bytes' -MaxSamples 1).CounterSamples.CookedValue / 1GB, 2) } catch {}
if ($memTotal -gt 0 -and $memAvail -ne $null) { $memPct = [math]::Round(($memTotal - $memAvail) / $memTotal * 100, 1) }

# ---- Disk (Win32_LogicalDisk) ----
$disk = @()
try {
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [PSCustomObject]@{
      drive = $_.DeviceID
      total = [math]::Round($_.Size / 1GB, 0)
      free  = [math]::Round($_.FreeSpace / 1GB, 0)
      pct   = if ($_.Size -gt 0) { [math]::Round(($_.Size - $_.FreeSpace) / $_.Size * 100, 1) } else { $null }
    }
  }
} catch {}

# ---- Egress latency: proxy-required endpoints vs direct-reachable endpoints ----
# Use .NET HttpWebRequest with a HARD .Timeout (socket-level, reliably enforced)
# instead of Invoke-WebRequest, which can ignore -TimeoutSec and hang forever.
$proxyUri = [System.Uri]'http://127.0.0.1:10808'
$endpoints = @(
  [PSCustomObject]@{ name='Anthropic'; url='https://api.anthropic.com'; via='proxy' }
  [PSCustomObject]@{ name='Codex';     url='https://api.openai.com';    via='proxy' }
  [PSCustomObject]@{ name='DeepSeek';  url='https://api.deepseek.com';  via='direct' }
  [PSCustomObject]@{ name='Kimi';      url='https://api.moonshot.cn';   via='direct' }
  [PSCustomObject]@{ name='Tushare';   url='https://tushare.pro';       via='direct' }
  [PSCustomObject]@{ name='GitHub';    url='https://github.com';        via='proxy' }
)
$latency = @()
foreach ($e in $endpoints) {
  $ms = $null; $ok = $false
  try {
    $req = [System.Net.HttpWebRequest]::Create($e.url)
    $req.Method = 'HEAD'
    $req.Timeout = 5000
    $req.ReadWriteTimeout = 5000
    $req.AllowAutoRedirect = $true
    if ($e.via -eq 'proxy') {
      $req.Proxy = New-Object System.Net.WebProxy($proxyUri, $false)
    } else {
      $req.Proxy = $null
    }
    $req.ServerCertificateValidationCallback = { $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $resp = $req.GetResponse()
      $ok = $true
      if ($resp) { $resp.Close() }
    } catch [System.Net.WebException] {
      # A response (even 4xx/5xx) means the target is reachable;
      # only a missing response is a real connection failure.
      if ($_.Exception.Response) { $ok = $true } else { $ok = $false }
    } catch { $ok = $false }
    $sw.Stop()
    $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
  } catch { $ok = $false; $ms = $null }
  $latency += [PSCustomObject]@{ name = $e.name; ok = $ok; ms = $ms; via = $e.via }
}

# ---- Always write the JSON, even if some probes above returned null ----
$payload = [PSCustomObject]@{
  gpuName = $gpuName; gpuPct = $gpuPct; gpuAvail = $gpuAvail
  npuName = $npuName; npuPct = $npuPct; npuAvail = $npuAvail
  memTotal = $memTotal; memFree = $memFree; memAvail = $memAvail
  memStandby = $memStandby; memCached = $memCached; memPct = $memPct
  disk = $disk
  latency = $latency
  # 出口节点真实值不硬编码在公开仓库；优先环境变量，其次 config.local.json（已 gitignore）
  $localCfgPath = Join-Path $PSScriptRoot 'config.local.json'
  $cfg = @{}
  if (Test-Path $localCfgPath) { try { $cfg = Get-Content $localCfgPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { $cfg = @{} } }
  $tokyoExit = if ($env:TOKYO_EXIT) { $env:TOKYO_EXIT } elseif ($cfg.tokyoExit) { $cfg.tokyoExit } else { '0.0.0.0:0' }
  $tokyoGeo  = if ($env:TOKYO_GEO)  { $env:TOKYO_GEO }  elseif ($cfg.tokyoGeo)  { $cfg.tokyoGeo }  else { '（在 config.local.json 配置出口归属）' }
  exitIp = $tokyoExit.Split(':')[0]; exitPort = $(if ($tokyoExit.Contains(':')) { $tokyoExit.Split(':')[1] } else { '8443' }); exitGeo = $tokyoGeo
  ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}
# Write with a retry loop so a concurrent writer (e.g. the per-minute SYSTEM task)
# holding the file lock cannot cause a lost sample.
$json = $payload | ConvertTo-Json -Compress -Depth 4
$okWrite = $false
for ($attempt = 1; $attempt -le 5; $attempt++) {
  try {
    [System.IO.File]::WriteAllText($OUT, $json, [System.Text.Encoding]::ASCII)
    $okWrite = $true
    break
  } catch {
    Start-Sleep -Milliseconds 300
  }
}
if (-not $okWrite) { Write-Output "EXTRA_WRITE_FAIL" } else { Write-Output "EXTRA_OK" }
