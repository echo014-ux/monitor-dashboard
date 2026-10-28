# Switch MonitorDashboard scheduled-task action to hidden launch (wscript+vbs),
# then stop old instance, free 7890, restart, and verify. No console window.
# Usage: in any PowerShell run
#   & "C:\Users\lu_08\WorkBuddy\monitor_dashboard\switch_task_hidden.ps1"
$ErrorActionPreference = 'Continue'
$vbs = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\run_hidden.vbs'
$wd  = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'

# 1) stop old instance and free port 7890 (including the black-window node)
try { Stop-ScheduledTask -TaskName 'MonitorDashboard' -ErrorAction SilentlyContinue } catch {}
try {
  Get-NetTCPConnection -LocalPort 7890 -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
} catch {}
Start-Sleep -Seconds 1

# 2) switch task action to wscript + vbs (no window after launch)
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') -WorkingDirectory $wd
try {
  Set-ScheduledTask -TaskName 'MonitorDashboard' -Action $action | Out-Null
  Write-Host '[OK] task action switched to hidden launch (wscript + run_hidden.vbs)'
} catch { Write-Host ('[FAIL] switch failed: ' + $_.Exception.Message); exit 1 }

# 3) start now + verify
Start-ScheduledTask -TaskName 'MonitorDashboard'
Start-Sleep -Seconds 4
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:7890/api/ping' -TimeoutSec 5 -UseBasicParsing
  Write-Host ('[OK] dashboard hidden running HTTP=' + $r.StatusCode + ' -- black window can be closed, will not pop again')
} catch { Write-Host ('[WARN] not ready yet: ' + $_.Exception.Message + ' -- refresh http://127.0.0.1:7890/ later') }
