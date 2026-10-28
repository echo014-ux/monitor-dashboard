# Register dashboard as boot auto-start (run as ADMIN).
# Robust version: node.exe is the direct task action (no cmd.exe /C wrapper),
# WorkingDirectory pinned to the script dir, runs as SYSTEM at startup,
# restart-on-failure (3x/1min), infinite runtime.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$node = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
$server = Join-Path $here 'server.cjs'

try {
  $svc = New-Object -ComObject Schedule.Service
  $svc.Connect()
  $root = $svc.GetFolder('\')

  $task = $svc.NewTask(0)
  $task.RegistrationInfo.Description = 'Aquant env monitor dashboard (port 7890)'

  # principal: SYSTEM (service account, highest run level)
  $task.Principal.UserId = 'SYSTEM'
  $task.Principal.LogonType = 1
  $task.Principal.RunLevel = 1

  # trigger: at system startup
  $trig = $task.Triggers.Create(8)   # TASK_TRIGGER_STARTUP

  # action: node.exe server.cjs  (direct, no cmd wrapper) with cwd pinned
  $act = $task.Actions.Create(0)       # TASK_ACTION_EXEC
  $act.Path = $node
  $act.Arguments = ('"' + $server + '"')
  $act.WorkingDirectory = $here

  # settings
  $task.Settings.RestartCount = 3
  $task.Settings.RestartInterval = 'PT1M'
  $task.Settings.ExecutionTimeLimit = 'PT0S'
  $task.Settings.Enabled = $true
  $task.Settings.DisallowStartIfOnBatteries = $false
  $task.Settings.StopIfGoingOnBatteries = $false
  $task.Settings.MultipleInstances = 0    # ignore new instances if already running

  $root.RegisterTaskDefinition('MonitorDashboard', $task, 6, $null, $null, 1) | Out-Null
  Write-Host "OK: created boot auto-start task MonitorDashboard (SYSTEM, port 7890)"
  Write-Host "OK: action=node server.cjs, WorkingDirectory pinned, restart 3x/1min, infinite runtime"
} catch {
  Write-Host "FAIL: $_"
  Write-Host "Hint: run this script as administrator (right-click PowerShell -> Run as administrator)"
}
