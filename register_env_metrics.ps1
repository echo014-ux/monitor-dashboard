# Register EnvMetrics scheduled task.
# Run as ADMIN: right-click PowerShell -> Run as administrator.
# Effect: runs collect_extra.ps1 every 1 minute, writes state/extra_metrics.json,
#         feeding the dashboard with GPU/NPU, real memory (incl. cache), disk, Tokyo egress latency.
# Same SYSTEM mode as ProxyKeepalive: survives reboot, no login needed.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$taskName = 'EnvMetrics'
$ps1 = Join-Path $here 'collect_extra.ps1'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""

try {
  schtasks /Create /TN $taskName /TR $cmd /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F
  Write-Host "OK: created scheduled task $taskName (every 1 min, SYSTEM)"
  schtasks /Run /TN $taskName
  Start-Sleep -Seconds 3
  $f = Join-Path $here 'state\extra_metrics.json'
  if (Test-Path $f) { Write-Host "OK: extra_metrics.json created (hardware/latency now live)" }
  else { Write-Host "WARN: task created but first sample not written yet; refresh dashboard shortly" }
} catch {
  Write-Host "FAIL: $_"
  Write-Host "Hint: run this script as administrator (right-click PowerShell -> Run as administrator)"
}
