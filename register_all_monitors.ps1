# =============================================================================
# 一键注册全部「主机环境监控」开机自启项目 (run as ADMIN)
#   1) MonitorDashboard  - 端口 7890 监控面板, node server.cjs, SYSTEM @ startup, 崩溃自动重启
#   2) EnvMetrics        - 每分钟 collect_extra.ps1 -> state/extra_metrics.json (GPU/内存/磁盘/延迟)
#   3) ProxyKeepalive    - 每分钟 代理(10808)自愈看门狗
#   4) LeakSweep-Daily   - 每日内核池泄漏扫描
# 全部 SYSTEM 身份 -> 开机/不登录也能跑, 重启后自动恢复。
# 用法: 在【管理员】PowerShell 里执行
#   & "C:\Users\lu_08\WorkBuddy\monitor_dashboard\register_all_monitors.ps1"
# =============================================================================
$ErrorActionPreference = 'Continue'
$node = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'

function Reg-Result($name, $ok, $detail) {
  if ($ok) { Write-Host ("[OK]   " + $name + " -> " + $detail) }
  else     { Write-Host ("[FAIL] " + $name + " -> " + $detail) }
}

# ---------- 1) MonitorDashboard (SYSTEM, AtStartup, 崩溃重启) ----------
try {
  $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $root = $svc.GetFolder('\')
  $task = $svc.NewTask(0)
  $task.RegistrationInfo.Description = 'Aquant env monitor dashboard (port 7890)'
  $task.Principal.UserId = 'SYSTEM'; $task.Principal.LogonType = 1; $task.Principal.RunLevel = 1
  $trig = $task.Triggers.Create(8)   # TASK_TRIGGER_STARTUP
  $act = $task.Actions.Create(0)
  $act.Path = $node
  $act.Arguments = '"C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs"'
  $act.WorkingDirectory = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'
  $task.Settings.RestartCount = 3; $task.Settings.RestartInterval = 'PT1M'
  $task.Settings.ExecutionTimeLimit = 'PT0S'; $task.Settings.Enabled = $true
  $task.Settings.DisallowStartIfOnBatteries = $false; $task.Settings.StopIfGoingOnBatteries = $false
  $task.Settings.MultipleInstances = 0
  $root.RegisterTaskDefinition('MonitorDashboard', $task, 6, $null, $null, 1) | Out-Null
  Reg-Result 'MonitorDashboard' $true 'SYSTEM@startup, restart 3x/1min'
} catch { Reg-Result 'MonitorDashboard' $false $_ }

# ---------- 2) EnvMetrics (每分钟 SYSTEM) ----------
try {
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\lu_08\WorkBuddy\monitor_dashboard\collect_extra.ps1"'
  & schtasks.exe /Create /TN 'EnvMetrics' /TR $tr /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
  Reg-Result 'EnvMetrics' ($LASTEXITCODE -eq 0) "schtasks exit=$LASTEXITCODE"
} catch { Reg-Result 'EnvMetrics' $false $_ }

# ---------- 3) ProxyKeepalive (每分钟 SYSTEM) ----------
try {
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\lu_08\WorkBuddy\proxy_keepalive\proxy_keepalive.ps1"'
  & schtasks.exe /Create /TN 'ProxyKeepalive' /TR $tr /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Null
  Reg-Result 'ProxyKeepalive' ($LASTEXITCODE -eq 0) "schtasks exit=$LASTEXITCODE"
} catch { Reg-Result 'ProxyKeepalive' $false $_ }

# ---------- 4) LeakSweep-Daily (每日 09:00 SYSTEM) ----------
try {
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\lu_08\WorkBuddy\Claw\LeakSweep-Daily.ps1"'
  & schtasks.exe /Create /TN 'LeakSweep-Daily' /TR $tr /SC DAILY /ST 09:00 /RU SYSTEM /RL HIGHEST /F | Out-Null
  Reg-Result 'LeakSweep-Daily' ($LASTEXITCODE -eq 0) "schtasks exit=$LASTEXITCODE"
} catch { Reg-Result 'LeakSweep-Daily' $false $_ }

Write-Host "`n=== 立即全部跑一次 ==="
foreach ($tn in @('MonitorDashboard','EnvMetrics','ProxyKeepalive','LeakSweep-Daily')) {
  try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop; Write-Host ("[RUN] " + $tn) }
  catch { & schtasks.exe /Run /TN $tn | Out-Null; Write-Host ("[RUN] " + $tn + " (schtasks)") }
}
Start-Sleep -Seconds 5
Write-Host "`n=== 7890 端口探测 ==="
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:7890/' -TimeoutSec 5 -UseBasicParsing
  Write-Host ("[OK] dashboard HTTP=" + $r.StatusCode)
} catch { Write-Host ("[WARN] dashboard not yet reachable: " + $_.Exception.Message) }
