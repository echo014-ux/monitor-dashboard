# Ensure monitor_dashboard (port 7890) stays resident via Scheduled Task.
# Current-user AtLogOn trigger (no admin needed), infinite runtime, auto-restart on crash.
$ErrorActionPreference = 'Continue'
$node = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
$server = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs'
$wd = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'

# 1) free port 7890 if anything occupies it
try {
  $occ = Get-NetTCPConnection -LocalPort 7890 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess
  foreach ($pidv in $occ) { try { Stop-Process -Id $pidv -Force -ErrorAction SilentlyContinue } catch {} }
} catch {}
Start-Sleep -Seconds 1

# 2) register scheduled task (current user, AtLogOn, infinite runtime, auto-restart)
$action = New-ScheduledTaskAction -Execute $node -Argument $server -WorkingDirectory $wd
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

try {
  Register-ScheduledTask -TaskName "MonitorDashboard" -Action $action -Trigger $trigger -Settings $settings -Force
  Write-Host "REGISTERED current-user AtLogOn"
} catch {
  Write-Host ("REGISTER_FAIL: " + $_.Exception.Message)
}

# 3) start now
try { Start-ScheduledTask -TaskName "MonitorDashboard"; Write-Host "STARTED" }
catch { Write-Host ("START_FAIL: " + $_.Exception.Message) }

Start-Sleep -Seconds 4
try { $ts = Get-ScheduledTask -TaskName "MonitorDashboard"; Write-Host ("TASK_STATE=" + $ts.State) } catch {}
try {
  $r = Invoke-WebRequest -Uri "http://localhost:7890/" -TimeoutSec 5 -UseBasicParsing
  Write-Host ("HTTP=" + $r.StatusCode)
} catch { Write-Host ("HTTP_FAIL: " + $_.Exception.Message) }
