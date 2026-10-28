# 后台常驻启动 monitor_dashboard (端口 7890)，不依赖当前窗口、不弹黑框。
# 用法: 在【任意】PowerShell 窗口执行
#   & "C:\Users\lu_08\WorkBuddy\monitor_dashboard\start_dashboard_bg.ps1"
# 进程以隐藏窗口方式常驻，直到手动结束或重启。
# 结束后台: 任务管理器结束 node server.cjs，或
#   Stop-Process -Name node -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Continue'
$node   = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
$server = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs'
$wd     = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'

if (-not (Test-Path $node))   { Write-Host "FATAL: node 不存在 -> $node"; exit 1 }
if (-not (Test-Path $server)) { Write-Host "FATAL: server.cjs 不存在 -> $server"; exit 1 }

# 如果已经有人在跑 7890，先释放
try {
  Get-NetTCPConnection -LocalPort 7890 -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
} catch {}

# 以隐藏窗口方式启动，进程脱离当前会话常驻
$proc = Start-Process -FilePath $node -ArgumentList $server -WorkingDirectory $wd -WindowStyle Hidden -PassThru

Start-Sleep -Seconds 4
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:7890/' -TimeoutSec 5 -UseBasicParsing
  Write-Host ("[OK] dashboard 已后台常驻, HTTP=" + $r.StatusCode + "  PID=" + $proc.Id)
  Write-Host "[OK] 浏览器打开 http://127.0.0.1:7890/"
} catch {
  Write-Host ("[WARN] 已启动 PID=" + $proc.Id + " 但暂未就绪: " + $_.Exception.Message)
  Write-Host "[WARN] 稍后刷新 http://127.0.0.1:7890/ 看看"
}
