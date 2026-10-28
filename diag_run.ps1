# Diagnostic: writes everything to state/diag.log (ASCII) so the agent can read it.
$log = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\state\diag.log'
function L($m){ $m | Out-File $log -Append -Encoding ascii }
"==== DIAG $(Get-Date) ====" | Out-File $log -Encoding ascii -Force

# 1) port 7890 + owning process
L "--- port 7890 ---"
$p = Get-NetTCPConnection -LocalPort 7890 -ErrorAction SilentlyContinue
if ($p) {
  L ("LISTENING: LocalAddress=" + $p.LocalAddress + " State=" + $p.State + " PID=" + $p.OwningProcess)
  $pr = Get-Process -Id $p.OwningProcess -ErrorAction SilentlyContinue
  if ($pr) { L ("owner path: " + $pr.Path) } else { L "owner process not found" }
} else { L "NOT LISTENING" }

# 2) real-host HTTP fetch (localhost + 127.0.0.1)
L "--- http fetch (real host) ---"
foreach ($h in @('http://localhost:7890/','http://127.0.0.1:7890/')) {
  try {
    $r = Invoke-WebRequest -Uri $h -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
    $body = $r.Content
    $head = if ($body.Length -gt 200) { $body.Substring(0,200) } else { $body }
    L ($h + " => HTTP " + $r.StatusCode + " len=" + $body.Length + " head=" + $head)
  } catch {
    L ($h + " => FAIL: " + $_.Exception.Message)
  }
}

# 3) shape of disk/latency in extra_metrics.json
L "--- extra_metrics.json shape ---"
$f = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\state\extra_metrics.json'
if (Test-Path $f) {
  try {
    $j = Get-Content $f -Raw | ConvertFrom-Json
    L ("disk type=" + $j.disk.GetType().Name + " isArray=" + ($j.disk -is [Array]) + " count=" + @($j.disk).Count)
    L ("latency type=" + $j.latency.GetType().Name + " count=" + @($j.latency).Count)
  } catch { L ("JSON parse fail: " + $_.Exception.Message) }
} else { L "extra_metrics.json MISSING" }

# 4) start node foreground, capture stdout/stderr, then kill if alive
L "--- node foreground test ---"
$node = 'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
$server = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $node
$psi.Arguments = $server
$psi.WorkingDirectory = 'C:\Users\lu_08\WorkBuddy\monitor_dashboard'
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$p2 = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 6
if (-not $p2.HasExited) { L "NODE STILL RUNNING (no crash)"; try { $p2.Kill() } catch {} ; Start-Sleep -Seconds 1 }
else { L ("NODE EXITED code=" + $p2.ExitCode) }
$out = $p2.StandardOutput.ReadToEnd()
$err = $p2.StandardError.ReadToEnd()
L ("STDOUT: " + $out)
L ("STDERR: " + $err)
"==== END ====" | Out-File $log -Append -Encoding ascii
L "DONE"
