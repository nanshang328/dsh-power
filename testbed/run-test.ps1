# Sandbox test runner for the dsh-power restart engine. It NEVER touches the real app:
# the fake app is FakeDsh.exe (a copy of node) on ports 19501/19502, name-matched only
# as "FakeDsh". Usage: run-test.ps1 -Scenario A|B|C [-RespawnMs N]
param(
  [string]$Scenario = 'A',
  [int]$RespawnMs = 0
)
$ErrorActionPreference = 'Continue'
$tb = $PSScriptRoot
$exe = Join-Path $tb 'FakeDsh.exe'
$statePort = 19501
$lockPort  = 19502
$log  = Join-Path $tb ("engine-$Scenario.log")
$stat = Join-Path $tb ("engine-$Scenario.json")
foreach($f in @($log,$stat)){ Remove-Item $f -ErrorAction SilentlyContinue }
if (-not (Test-Path $exe)) {
  Write-Host ('FATAL: ' + $exe + ' is missing.')
  Write-Host 'FakeDsh.exe must be a COPY of node.exe: the engine matches processes by name, so the'
  Write-Host 'fake app has to look like a second install of DSH. Create it with one of:'
  Write-Host '  Copy-Item (Get-Command node).Source .\FakeDsh.exe'
  Write-Host '  Copy-Item "<DSH>\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" .\FakeDsh.exe'
  exit 9
}

function PortServing([int]$port, [ref]$pidOut) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$port/api/dsh-power/status") -TimeoutSec 2 -UseBasicParsing -EA Stop
    if ($r.StatusCode -eq 200) { $j = $r.Content | ConvertFrom-Json; $pidOut.Value = [int]$j.pid; return ($j.ok -eq $true) }
  } catch { }
  $pidOut.Value = 0; return $false
}
function KillAllFake() {
  Get-Process -Name 'FakeDsh' -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -EA Stop } catch {} }
  Start-Sleep -Milliseconds 400
}

Write-Host "=== scenario $Scenario respawn=$RespawnMs : boot the fake app ==="
KillAllFake
# Scenario C runs a SECOND fake instance (its own lock+state ports) that must be left
# completely untouched: that is the multi-instance guarantee of the own-tree mode.
$otherPids = @()
if ($Scenario -eq 'C') {
  $otherTail = '"' + (Join-Path $tb 'fake-shell.cjs') + '" --state-port 19503 --lock-port 19504 --respawn-ms 0'
  $other = Start-Process $exe -ArgumentList $otherTail -WindowStyle Hidden -PassThru
  $op = 0; $od = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $od) { Start-Sleep -Milliseconds 300; if (PortServing 19503 ([ref]$op)) { break } }
  if ($op -eq 0) { Write-Host 'FATAL: other fake never served'; KillAllFake; exit 9 }
  $otherPids = @(Get-Process -Name 'FakeDsh' -EA SilentlyContinue | Select-Object -Expand Id)
  Write-Host ("other fake up (must survive): " + ($otherPids -join ','))
}
$tail = '"' + (Join-Path $tb 'fake-shell.cjs') + '" --state-port ' + $statePort + ' --lock-port ' + $lockPort + ' --respawn-ms ' + $RespawnMs
$shell = Start-Process $exe -ArgumentList $tail -WindowStyle Hidden -PassThru
$booted = $false; $p0 = 0; $deadline=(Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; if (PortServing $statePort ([ref]$p0)) { $booted=$true; break } }
if (-not $booted) { Write-Host 'FATAL: fake app never served'; KillAllFake; exit 9 }
$fakePids = @(Get-Process -Name 'FakeDsh' -EA SilentlyContinue | Select-Object -Expand Id)
Write-Host ("fake up: state pid=$p0 shell pid=" + $shell.Id + " all=" + ($fakePids -join ','))

if ($Scenario -eq 'C') {
  # a SECOND, older fake instance holds the single-instance lock and serves the port.
  # The engine must NOT kill it (it is not ours in the tree sense, and here HostPid=0 means
  # legacy kill-all, so the real protection under test is: relaunch into it = stub, engine
  # must notice fast and say lock-held-by-other instead of burning 30s per try).
  Write-Host '=== scenario C: second instance already owns the lock ==='
}

Write-Host "=== run the engine ==="
$t0 = Get-Date
$eng = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $tb '..\scripts\restart-dsh.ps1'),
  '-ProcessName','FakeDsh','-ExePath',$exe,'-LaunchArgs',$tail,
  '-Port',"$statePort",'-HostPid',"$($shell.Id)",'-LogPath',$log,'-StatusPath',$stat,
  '-NoForeground','-WaitStartSeconds','20','-StartTries','3','-WatchAfterReadySeconds','5',
  '-Reason',"test-$Scenario" -WindowStyle Hidden -PassThru
$fin = $eng.WaitForExit(60000)
$el = [int]((Get-Date)-$t0).TotalSeconds
Write-Host ("engine exited=$fin code=" + $(if($fin){$eng.ExitCode}else{'TIMEOUT'}) + " wall=${el}s")
Write-Host '--- engine log ---'
if (Test-Path $log) { Get-Content $log }
Write-Host '--- engine status ---'
if (Test-Path $stat) { Get-Content $stat -Raw }
$servingPid = 0; $serving = PortServing $statePort ([ref]$servingPid)
$left = @(Get-Process -Name 'FakeDsh' -EA SilentlyContinue | Select-Object -Expand Id)
Write-Host ("after: serving=$serving pid=$servingPid aliveFake=" + ($left -join ','))
$verdict = 'FAIL'
if ($Scenario -eq 'C') {
  $survivors = @($otherPids | Where-Object { $left -contains $_ })
  $otherServing = $false; $opid = 0
  $otherServing = PortServing 19503 ([ref]$opid)
  Write-Host ("other-instance: pids_surviving=" + ($survivors.Count) + "/" + ($otherPids.Count) + " serving=" + $otherServing + " pid=" + $opid)
  if ($serving -and $survivors.Count -eq $otherPids.Count -and $otherServing) { $verdict = 'PASS' } else { $verdict = 'FAIL' }
} else {
  if ($serving) { $verdict = 'PASS' }
}
Write-Host ("SCENARIO $Scenario => $verdict")
KillAllFake
Write-Host '=== fakes cleaned ==='
exit $(if ($verdict -eq 'PASS') { 0 } else { 1 })

