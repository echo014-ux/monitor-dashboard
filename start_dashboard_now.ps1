# 在主机上直接前台启动 monitor_dashboard (端口 7890)。
# 用法: 在你自己的 PowerShell 窗口里执行
#   & "C:\Users\lu_08\WorkBuddy\monitor_dashboard\start_dashboard_now.ps1"
# 保持窗口不关 = 服务常驻；Ctrl+C 停止。

$ErrorActionPreference = 'Continue'
$node   = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
$server = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs'
$wd     = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'

if (-not (Test-Path $node))   { Write-Host "FATAL: node 不存在 -> $node"; exit 1 }
if (-not (Test-Path $server)) { Write-Host "FATAL: server.cjs 不存在 -> $server"; exit 1 }

# 释放被占用的 7890
try {
  Get-NetTCPConnection -LocalPort 7890 -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
} catch {}
Start-Sleep -Seconds 1

Set-Location $wd
Write-Host "[start] node = $node"
Write-Host "[start] url  = http://127.0.0.1:7890/"
& $node $server