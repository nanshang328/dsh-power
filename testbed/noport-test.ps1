# Hand-run mode test: the README tells a human to run restart-dsh.ps1 by hand, and that
# path has NO status route to probe (Port 0). It used to (a) poll the launch budget to the
# very end and (b) then report the healthy relaunch as 'teardown' with exit code 3, because
# the watch phase asked a port that never existed. This checks both fixes.
$ErrorActionPreference = 'Continue'
$tb = $PSScriptRoot
$exe = Join-Path $tb 'FakeDsh.exe'
$log  = Join-Path $tb 'engine-noport.log'
$stat = Join-Path $tb 'engine-noport.json'
foreach($f in @($log,$stat)){ Remove-Item $f -ErrorAction SilentlyContinue }
if (-not (Test-Path $exe)) {
  Write-Host ('FATAL: ' + $exe + ' is missing; it must be a copy of node.exe (see testbed\README.md).')
  exit 9
}

function KillAllFake() {
  Get-Process -Name 'FakeDsh' -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -EA Stop } catch {} }
  Start-Sleep -Milliseconds 400
}

Write-Host '=== no-port (hand-run) test: boot a fake with no served status port ==='
KillAllFake
$tail = '"' + (Join-Path $tb 'fake-shell.cjs') + '" --state-port 0 --lock-port 19505 --respawn-ms 0'
$shell = Start-Process $exe -ArgumentList $tail -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1500
if (-not (Get-Process -Id $shell.Id -EA SilentlyContinue)) { Write-Host 'FATAL: fake shell died'; exit 9 }
Write-Host ('fake up: shell pid=' + $shell.Id + ' (no port served)')

Write-Host '=== run the engine with -Port 0 ==='
$t0 = Get-Date
$eng = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $tb '..\scripts\restart-dsh.ps1'),
  '-ProcessName','FakeDsh','-ExePath',$exe,'-LaunchArgs',$tail,
  '-Port','0','-HostPid',"$($shell.Id)",'-LogPath',$log,'-StatusPath',$stat,
  '-NoForeground','-WaitStartSeconds','20','-StartTries','3','-WatchAfterReadySeconds','5',
  '-Reason','test-noport' -WindowStyle Hidden -PassThru
$fin = $eng.WaitForExit(60000)
$el = [int]((Get-Date)-$t0).TotalSeconds
$code = if($fin){$eng.ExitCode}else{'TIMEOUT'}
Write-Host ("engine exited=$fin code=$code wall=${el}s")
Write-Host '--- engine log ---'
if (Test-Path $log) { Get-Content $log }
Write-Host '--- engine status ---'
$raw = if (Test-Path $stat) { Get-Content $stat -Raw } else { '' }
if ($raw) { Write-Host $raw }
$left = @(Get-Process -Name 'FakeDsh' -EA SilentlyContinue | Select-Object -Expand Id)
Write-Host ('after: aliveFake=' + ($left -join ','))

$verdict = 'FAIL'
$stage = ''; $result = ''; $newPid = 0
try { $j = $raw | ConvertFrom-Json; $stage = [string]$j.stage; $result = [string]$j.result; $newPid = [int]$j.newPid } catch { }
# last.json carries stage/result (no 'ok' field); 'ready'+'ok' means the helper called its own
# relaunch good, and exit=0 (not the old 3/-teardown) is the fix under test.
$alive = ($newPid -gt 0) -and (@($left) -contains $newPid)
if ($code -eq 0 -and $stage -eq 'ready' -and $result -eq 'ok' -and $alive) { $verdict = 'PASS' }
Write-Host ("NOPORT TEST => $verdict (exit=$code stage=$stage result=$result newPid=$newPid alive=$alive)")
KillAllFake
Write-Host '=== fakes cleaned ==='
exit $(if ($verdict -eq 'PASS') { 0 } else { 1 })