# dsh-power - the one authoritative restart script.
#
# ASCII ONLY. Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so Chinese comments
# in this file turn into mojibake - and a mangled multi-byte character can even swallow
# the following newline, merging the next code line into the comment and breaking the
# parser ("Try statement is missing its Catch or Finally block"). English only, always.
#
# Sequence: acquire mutex -> record target pids -> stop exactly those pids -> confirm they
# are gone -> wait for the web port to free -> create the new instance outside our job ->
# confirm it came up -> push its window to the foreground -> release -> (watch) -> exit.
#
# Designs that each came from a real failure:
#
#   1) Mutex Global\dsh-power-restart: two restarters must never run at once, otherwise
#      the later one kills the instance the earlier one just brought up.
#
#   2) Every process of OUR instance is a target, INCLUDING the Electron shell.
#      The shell (DeepSeek Harness.exe, the GUI process) supervises the host child and
#      auto-restarts it when it dies. A restarter that kills only the host leaves the
#      shell alive, the shell races the helper for the web port, and whichever loses
#      dies with EADDRINUSE. Killing shell + host together means nobody is left to race.
#
#   3) The launch goes through WMI (Win32_Process.Create), not Start-Process/start.
#      The helper itself is spawned by the app, so it lives inside the host's Job Object;
#      when the host is force-killed the job closes and every process the helper started
#      is terminated by the OS. That is exactly "launch issued, but it never came up".
#      WMI creates the process from the WMI service, outside that job.
#
#   4) After the relaunch we wait for the web port to actually answer, not just for a pid
#      to exist. "A process with the right name exists" is not "DSH is usable again".
#
#   5) Once the new instance is up we push its window to the front. A WMI-launched process
#      gets no foreground rights, so the new window lands behind whatever was on top -
#      a fullscreen game left the restart looking like nothing had happened. Windows
#      refuses SetForegroundWindow to background processes (the foreground lock), so we tap
#      ALT through keybd_event and share input queues with the current foreground thread.
#
#   6) Multi-instance safety: killing "every process with this name" also kills OTHER
#      instances. The killer targets only THIS instance's process tree: from the host pid
#      the plugin passes (-HostPid), climb to the topmost ancestor that is still same-named
#      (the Electron shell), then take that shell plus every same-named descendant. Another
#      instance has a different shell, so it is never in the set. Without -HostPid
#      (hand-run) we fall back to the old all-named behavior; -KillAllNamed forces it.
#      -Explain prints both sets and exits without killing anything.
#
#   7) The schtasks fallback used to leave "dsh-power-restart-once" registered forever.
#      It is now deleted right after the run is issued.
#
#   8) A LAUNCH MAY BE A NO-OP, AND THAT MUST BE SEEN IN MILLISECONDS, NOT SECONDS.
#      The app claims a single-instance lock (Electron requestSingleInstanceLock: the
#      second copy quits itself, measured at about 90ms, and only fires "second-instance"
#      on the owner). So a launch issued while something still holds that lock is a STUB:
#      WMI reports success, hands back a pid, and that pid then dies on its own.
#      0.6.0 could not see this. It read "no answer yet" as "still booting" and polled for
#      30 seconds per attempt, so one stub cost 30 seconds and a three-attempt restart took
#      92 seconds of wall time to do 13 seconds of real work. The loop now watches the very
#      pid it launched: gone, with nothing same-named left booting, means stub - log it and
#      retry about 300ms later instead of 30s later.
#
#   9) Never launch while one is already booting. When every failed attempt burned 30s the
#      retries were spaced far enough apart to never collide; fast retries would happily run
#      two boots at once, and two instances racing the web port is note 2's EADDRINUSE
#      crash. So before firing we look for same-named processes that are NOT part of the
#      killed batch, and wait instead of stacking a launch on top of them.
#
#  10) "Ready" is a claim, not a fact, until the instance has stayed up. A 0.6.0 restart
#      logged stage=ready/result=ok at 16:58:11 while the host log shows that instance
#      tearing itself down 13 seconds later and ANOTHER one appearing - the helper had
#      already exited and recorded none of it. After reporting ready the helper now watches
#      for WatchAfterReadySeconds (mutex released FIRST, so a follow-up restart by a human
#      is never blocked) and writes what it saw into the status file. 0 disables this.
#
# No window is ever shown; $ErrorActionPreference stays Continue and every failure is
# written to the log instead of being swallowed. Every log line carries the elapsed seconds
# so a slow restart says where the seconds went without a timestamp diff after the fact.

param(
  [string]$ProcessName = 'DeepSeek Harness',
  [string]$ExePath = '',
  [string]$LogPath = (Join-Path $PSScriptRoot 'restart-dsh.log'),
  [string]$Reason = 'manual',
  [string]$StatusPath = '',
  [int]$Port = 0,
  [int]$HostPid = 0,
  # how long the killed batch may take to really disappear
  [int]$WaitClosedSeconds = 20,
  # how long we wait for the web port to become bindable
  [int]$WaitPortSeconds = 60,
  # TOTAL budget for "an instance is serving", shared by all attempts (0.6.0 spent 30s PER attempt)
  [int]$WaitStartSeconds = 25,
  # maximum number of launches inside that budget
  [int]$StartTries = 4,
  # poll interval while watching a launch, in ms
  [int]$LaunchPollMs = 250,
  # cap for the foreground push (0.6.0 hardcoded 15s and usually ended in no-window)
  [int]$ForegroundSeconds = 4,
  # after ready: keep watching this long to catch an instance that tears itself down
  [int]$WatchAfterReadySeconds = 20,
  # appended to the launch command line after the exe path. Empty in production (the bare
  # exe carries everything, exactly as before); the sandboxed testbed uses it to hand the
  # fake app its ports. One knob that makes the REAL engine end-to-end testable without
  # touching the real app - "relaunch" is the step dry-run could never cover.
  [string]$LaunchArgs = '',
  [switch]$DryRun,
  [switch]$ShutdownOnly,
  [switch]$NoForeground,
  [switch]$KillAllNamed,   # force the old "kill every named pid" behavior
  [switch]$Explain         # print which pids WOULD be killed, then exit without killing
)

$ErrorActionPreference = 'Continue'
$script:Sw = [System.Diagnostics.Stopwatch]::StartNew()

function Log([string]$message) {
  $line = (Get-Date -Format 'HH:mm:ss.fff') + ' [+' + ([int]$script:Sw.Elapsed.TotalSeconds) + 's] ' + $message
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# A machine-readable record of the last power action, next to the human log. The plugin
# serves it back over /api/dsh-power/status and power_status, so "did the last restart
# actually work" is answerable after the fact instead of only by reading the log.
$script:Stage = 'start'
function Write-Status([string]$stage, [string]$result, [hashtable]$extra) {
  $script:Stage = $stage
  if ([string]::IsNullOrWhiteSpace($StatusPath)) { return }
  $record = [ordered]@{
    action = $(if ($ShutdownOnly) { 'shutdown' } else { 'restart' })
    stage = $stage
    result = $result
    reason = $Reason
    processName = $ProcessName
    exePath = $ExePath
    port = $Port
    helperPid = $PID
    startedAt = $script:StartedAt
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    elapsedSeconds = [math]::Round($script:Sw.Elapsed.TotalSeconds, 1)
  }
  if ($extra) { foreach ($key in $extra.Keys) { $record[$key] = $extra[$key] } }
  try {
    $dir = [System.IO.Path]::GetDirectoryName($StatusPath)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
      $null = New-Item -ItemType Directory -Path $dir -Force
    }
    ($record | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StatusPath -Encoding UTF8
  } catch {
    Log ('status write failed: ' + $_.Exception.Message)
  }
}

function Get-TargetIds([string]$name) {
  try {
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  } catch {
    Log ('Get-Process failed: ' + $_.Exception.Message)
    return @()
  }
}

function Test-PidAlive([int]$procId) {
  if ($procId -le 0) { return $false }
  return [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

# Same-named processes that are NOT in the batch we just killed. After the kill these can
# only be (a) our own new instance mid-boot or (b) another instance holding the
# single-instance lock. Launching into either is wrong: (a) races the web port, (b) is a
# guaranteed stub. Empty means the field is clear and a launch is worth firing.
function Get-ForeignIds([string]$name, $killed) {
  $all = @(Get-TargetIds $name)
  if ($all.Count -eq 0) { return @() }
  if ($null -eq $killed) { return $all }
  return @($all | Where-Object { $killed -notcontains [int]$_ })
}

# Same-named processes that STARTED AFTER we began the kill. Two kinds, and both matter:
#
#   - before step 3: a process the dying Electron shell RESPAWNED. The target list is a
#     snapshot taken before the kills, so a respawn is invisible to "did my batch die" -
#     it lets step 2 report confirmed-closed=true while a whole live instance is still
#     standing. That survivor then holds the single-instance lock, which is exactly what
#     turned 0.6.0's first two launches into stubs that cost 30 seconds each. The settle
#     loop below hunts these down and kills them.
#   - during step 3: our own boot in progress. This is what the no-stacking check (note 9)
#     and the stub check (note 8) care about.
#
# Get-ForeignIds alone is NOT usable for either: a long-lived second instance is foreign
# too, and treating it as "field busy" (or killing it) would break the multi-instance
# guarantee that 0.6.0 exists to provide. AGE is what separates "our instance, respawned or
# booting" from "another instance that was already running".
# Processes whose start time we cannot read count as young: blocking a retry is cheaper
# than stacking two boots onto one web port.
function Get-YoungForeignIds([string]$name, $killed) {
  $since = $script:KillStartedAt
  if ($null -eq $since) { return @(Get-ForeignIds $name $killed) }
  $young = @()
  foreach ($procId in @(Get-ForeignIds $name $killed)) {
    try {
      $proc = Get-Process -Id ([int]$procId) -ErrorAction Stop
      if ($proc.StartTime -gt $since) { $young += [int]$procId }
    } catch { $young += [int]$procId }
  }
  return @($young)
}

# What one poll tick tells us about a launch. Kept as a pure function so the classification
# that decides "stub or still booting" is unit-testable without restarting anything.
#   serving   -> the instance answers on the port: done
#   launched  -> the pid WMI reported is alive (unknown for the explorer/schtasks paths)
#   hasPid    -> do we actually know a pid to judge "the launch died" by?
#   young     -> processes of ours (started after our kill) that are not in the killed batch
function Get-LaunchVerdict([bool]$serving, [bool]$launched, [bool]$hasPid, [int]$young) {
  if ($serving) { return 'up' }
  if ($launched) { return 'waiting' }
  if ($young -gt 0) { return 'booting' }
  # Only a launch whose pid we KNOW can be proven dead. Via explorer/schtasks the boot is
  # invisible to us and 'not launched' says nothing - waiting beats a false stub that would
  # stack a second launch onto a boot already in progress.
  if ($hasPid) { return 'stub' }
  return 'waiting'
}

# Resolve the executable when the caller did not pass one. The plugin normally passes
# process.execPath, but a hand-run of this script should still work.
function Resolve-ExePath([string]$given) {
  if (-not [string]::IsNullOrWhiteSpace($given) -and (Test-Path -LiteralPath $given)) { return $given }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  try {
    $found = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
      Where-Object { $_.Path } | Select-Object -First 1 -ExpandProperty Path)
    if ($found.Count -gt 0 -and $found[0]) { return $found[0] }
  } catch { }
  return $given
}

function Test-PortFree([int]$port) {
  if ($port -le 0) { return $true }
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $async = $client.BeginConnect('127.0.0.1', $port, $null, $null)
      $ok = $async.AsyncWaitHandle.WaitOne(400)
      if (-not $ok) { return $true }   # nobody answered -> treat as free
      try { $client.EndConnect($async); return $false } catch { return $true }
    } finally { $client.Close() }
  } catch {
    return $true
  }
}

# Readiness probe.
#
# Do NOT probe the core /health route: every core route sits behind the web token, so an
# unauthenticated GET gets 401 and a perfectly healthy instance looks dead. A plugin's own
# route is served by the plugin and needs no token, so we ask dsh-power itself. That also
# makes the answer specific: the pid in the reply must differ from the old instance, which
# is the difference between "something is listening" and "the NEW instance is up".
function Get-InstanceStatus([int]$port) {
  if ($port -le 0) { return $null }
  try {
    $response = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/api/dsh-power/status') `
      -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($response.StatusCode -ne 200) { return $null }
    return ($response.Content | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-Health([int]$port) {
  $status = Get-InstanceStatus $port
  if ($null -eq $status) { return $false }
  return ($status.ok -eq $true)
}

# Is an instance of OUR app serving on the port, and is it one WE brought up?
#
# "Answering" is not enough: a second, pre-existing instance answers identically, and 0.6.0
# would have called that readiness (its only filter was "pid not in my killed batch"). The
# new instance's host necessarily started AFTER our kill, so requiring a young pid tells
# "the instance I relaunched is up" apart from "someone else's instance is up".
function Test-InstanceUp([int]$port, $killed, [string]$name) {
  if ($port -le 0) { return $false }
  $status = Get-InstanceStatus $port
  if ($null -eq $status) { return $false }
  if ($status.ok -ne $true) { return $false }
  $servingPid = [int]$status.pid
  if ($servingPid -le 0) { return $false }
  return (@(Get-YoungForeignIds $name $killed) -contains $servingPid)
}

# ---------------------------------------------------------------- multi-instance safety
#
# One DSH instance = one Electron shell process named $ProcessName, under which sit the
# host and its GPU/utility/renderer children (also named $ProcessName). A SECOND DSH
# instance has its own shell with its own subtree. So "our instance" is exactly:
#
#   climb from the host pid (passed by the plugin as -HostPid) up through same-named
#   parents until the parent is NOT same-named (services.exe, explorer, a console, ...)
#   -> that topmost same-named ancestor is our shell. Our tree = the shell plus every
#   same-named descendant of the shell. Another instance's shell is a different root,
#   so it can never appear in this set.
#
# Parent links come from Win32_Process (CIM). Get-Process has no ParentId on PS 5.1, and
# matching by executable PATH cannot tell two instances apart - they share one path.

function Get-ProcessLinks {
  try {
    # -OperationTimeoutSec: a hung WMI call must not hang the helper. This runs after the
    # old instance is already dead, so an unbounded wait here leaves the app down with
    # nobody left to relaunch it. 20s is far above the normal sub-second enumeration.
    return @(Get-CimInstance -ClassName Win32_Process `
      -Property ProcessId, ParentProcessId, Name -OperationTimeoutSec 20 -ErrorAction Stop)
  } catch {
    Log ('CIM process enumeration failed: ' + $_.Exception.Message)
    return $null
  }
}

function Resolve-OwnTree([int]$hostPid, [string]$name, $links) {
  if ($hostPid -le 0) { return @() }
  # Win32_Process.Name always carries the extension ("DeepSeek Harness.exe") while
  # $ProcessName does not. Normalize BOTH sides before comparing, or nothing ever
  # matches and the "tree" collapses to the host pid alone - which would leave the
  # shell alive to race the new instance for the port (design note 2).
  $leaf = ($name -replace '\.exe$', '')
  $byPid = @{}
  foreach ($row in $links) { $byPid[[int]$row.ProcessId] = $row }
  if (-not $byPid.ContainsKey($hostPid)) { return @() }
  # climb to the topmost same-named ancestor (the shell), guarding against cycles
  $shell = $hostPid
  $steps = 0
  while ($steps -lt 64) {
    $steps += 1
    $row = $byPid[$shell]
    $parent = [int]$row.ParentProcessId
    if ($parent -le 0 -or -not $byPid.ContainsKey($parent)) { break }
    if ((($byPid[$parent].Name) -replace '\.exe$', '') -ne $leaf) { break }
    $shell = $parent
  }
  # collect the shell plus every same-named descendant
  $kidsOf = @{}
  foreach ($row in $links) {
    $pp = [int]$row.ParentProcessId
    if (-not $kidsOf.ContainsKey($pp)) { $kidsOf[$pp] = @() }
    $kidsOf[$pp] += [int]$row.ProcessId
  }
  $tree = New-Object System.Collections.Generic.List[int]
  $seen = @{}
  $queue = @($shell)
  while ($queue.Count -gt 0) {
    $current = $queue[0]
    $queue = @($queue | Select-Object -Skip 1)
    if ($seen.ContainsKey($current)) { continue }
    if (-not $byPid.ContainsKey($current)) { continue }
    if ((($byPid[$current].Name) -replace '\.exe$', '') -ne $leaf) { continue }
    $seen[$current] = $true
    $tree.Add($current)
    if ($kidsOf.ContainsKey($current)) { $queue += $kidsOf[$current] }
  }
  return @($tree)
}

# Decide which pids to stop. Returns @{ mode; targets }.
function Resolve-TargetIds([string]$name, [int]$hostPid) {
  $all = @(Get-TargetIds $name)
  if ($KillAllNamed) {
    return @{ mode = 'kill-all-named(forced)'; targets = $all }
  }
  if ($hostPid -le 0) {
    # Hand-run without -HostPid: nothing to climb from; old behavior, loudly logged.
    Log 'no -HostPid given; falling back to stopping ALL named pids (legacy)'
    return @{ mode = 'kill-all-named(no-host-pid)'; targets = $all }
  }
  $links = Get-ProcessLinks
  if ($null -eq $links) {
    # WMI itself is unavailable (locked-down machine). Refusing here would make the
    # plugin dead-on-arrival there, so degrade to legacy-all-named with a warning.
    Log 'process links unavailable (CIM denied); falling back to stopping ALL named pids'
    return @{ mode = 'kill-all-named(no-cim)'; targets = $all }
  }
  $mine = @(Resolve-OwnTree $hostPid $name $links)
  if ($mine.Count -eq 0) {
    # We CAN see the tree and OUR host is not in it - something is very wrong.
    # Killing every named pid here is exactly the multi-instance footgun, so abort.
    Log 'own-tree empty; refusing to kill all named pids (multi-instance safety)'
    return @{ mode = 'aborted'; targets = @() }
  }
  $others = @($all | Where-Object { $mine -notcontains $_ })
  if ($Explain) {
    Log ('explain: all-named=' + ($all -join ','))
    Log ('explain: own-tree=' + ($mine -join ','))
    Log ('explain: other-instances=' + $(if ($others.Count -gt 0) { $others -join ',' } else { 'none' }))
    Log 'explain: nothing killed'
    Write-Status 'explain' 'ok' @{ all = @($all); own = @($mine); others = @($others) }
    exit 0
  }
  if ($others.Count -gt 0) {
    Log ('sparing ' + $others.Count + ' pid(s) of other instances: ' + ($others -join ','))
  }
  return @{ mode = 'own-tree'; targets = $mine }
}

$script:Win32Ready = $false
function Ensure-Win32 {
  if ($script:Win32Ready) { return $true }
  try {
    if (-not ('DshPower.Win32' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace DshPower {
  public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // The visible top-level window belonging to a pid, or Zero.
    //
    // This replaces the Get-Process .MainWindowHandle scan, which is why 0.6.0 burned a
    // hardcoded 15 seconds and logged foreground=no-window: that property is not reliably
    // set for the Electron shell, so the old loop never even obtained a handle to try.
    // Matching GetWindowThreadProcessId over EnumWindows finds the same window, and is the
    // technique the sibling card plugin already uses to bring the host forward.
    public static IntPtr FindWindowForPid(int targetPid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr lParam)
        {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLengthW(h) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if ((int)pid == targetPid) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Same, for every visible window of every pid in the set (a booting instance may own
    // the window under a pid other than the one WMI reported).
    public static string PidsWithWindows(int[] pids)
    {
        StringBuilder all = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr lParam)
        {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLengthW(h) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            foreach (int want in pids)
            {
                if ((int)pid == want)
                {
                    if (all.Length > 0) all.Append(',');
                    all.Append(want).Append(':').Append(h.ToInt64().ToString());
                    break;
                }
            }
            return true;
        }, IntPtr.Zero);
        return all.ToString();
    }
  }
}
'@ -ErrorAction Stop
    }
    $script:Win32Ready = $true
    return $true
  } catch {
    Log ('win32 api unavailable: ' + $_.Exception.Message)
    return $false
  }
}

# Push the freshly started window to the front, inside $ForegroundSeconds TOTAL.
# Returns: skipped | no-api | no-window | set | appactivate | appactivate-name | refused
function Bring-NewInstanceToFront([string]$name, [int]$newPid, $killed) {
  if ($NoForeground) { return 'skipped' }
  $handle = [IntPtr]::Zero
  $ownerPid = 0
  $deadline = (Get-Date).AddSeconds($ForegroundSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Ensure-Win32)) { return 'no-api' }
    # Preferred owner: the pid WMI created (that is the shell, and the shell owns the
    # window). Fallback: young same-named pids, i.e. boots that started after our kill -
    # NEVER old ones: raising another instance's window would be worse than no raise.
    $pids = @()
    if ($newPid -gt 0) { $pids += $newPid }
    $pids += @(Get-YoungForeignIds $name $killed)
    if ($pids.Count -eq 0) { Start-Sleep -Milliseconds 200; continue }
    $intPids = @($pids | ForEach-Object { [int]$_ })
    try {
      # One enumeration tells us which candidate actually owns a window.
      $pairs = [DshPower.Win32]::PidsWithWindows($intPids)
      if (-not [string]::IsNullOrEmpty($pairs)) {
        $first = ($pairs -split ',')[0] -split ':'
        $ownerPid = [int]$first[0]
        $handle = [IntPtr]([long]$first[1])
        break
      }
    } catch {
      Log ('window scan failed: ' + $_.Exception.Message)
      return 'no-api'
    }
    Start-Sleep -Milliseconds 200
  }
  if ($handle -eq [IntPtr]::Zero) { return 'no-window' }
  for ($try = 1; $try -le 3; $try++) {
    try {
      $fg = [DshPower.Win32]::GetForegroundWindow()
      $fgPid = [uint32]0
      $fgThread = [DshPower.Win32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
      $myThread = [DshPower.Win32]::GetCurrentThreadId()
      $attached = $false
      if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
        $attached = [DshPower.Win32]::AttachThreadInput($myThread, $fgThread, $true)
      }
      [DshPower.Win32]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)         # ALT down
      [DshPower.Win32]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)         # ALT up
      # Only un-minimize a minimized window; SW_RESTORE on a maximized one would
      # silently drop it back to windowed size.
      if ([DshPower.Win32]::IsIconic($handle)) { $null = [DshPower.Win32]::ShowWindow($handle, 9) }
      $null = [DshPower.Win32]::BringWindowToTop($handle)
      $ok = [DshPower.Win32]::SetForegroundWindow($handle)
      if ($attached) { $null = [DshPower.Win32]::AttachThreadInput($myThread, $fgThread, $false) }
      if ($ok -and ([DshPower.Win32]::GetForegroundWindow() -eq $handle)) {
        Log ('window handle found for pid=' + $ownerPid)
        return 'set'
      }
    } catch {
      Log ('foreground try ' + $try + ' threw: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 200
  }
  # Last resort: the shell's own activation path, which the OS treats differently.
  try {
    $com = New-Object -ComObject WScript.Shell
    if ($ownerPid -gt 0 -and $com.AppActivate($ownerPid)) { return 'appactivate' }
    if ($com.AppActivate($name)) { return 'appactivate-name' }
  } catch { }
  return 'refused'
}

# One launch, three paths, because none is universally available:
#   a) WMI (Win32_Process.Create) - created by the WMI service, so not in our job.
#   b) explorer.exe <exe> - created by the shell, also outside the job; always present.
#   c) Task Scheduler - created by the scheduler service, again outside the job.
# Returns @{ pid; via }. pid 0 = "issued, pid unknowable" (paths b and c).
# $tail is the testbed's extra command-line arguments; empty in production, which keeps
# every constructed string byte-identical to the real app's launch.
function Invoke-Launch([string]$exe, [string]$exeDir, [int]$attempt, [string]$tail) {
  $suffix = ''
  if (-not [string]::IsNullOrWhiteSpace($tail)) { $suffix = ' ' + $tail.Trim() }
  # The hashtable is built into a variable first on purpose: an inline @{...} followed by
  # -ErrorAction Stop makes the PowerShell 5.1 parser close the enclosing try block early.
  $wmiArgs = @{
    CommandLine = ('"' + $exe + '"' + $suffix)
    CurrentDirectory = $exeDir
  }
  try {
    # -OperationTimeoutSec matters more here than anywhere else: if the WMI service stalls,
    # we are the only thing that can still bring the app back. A bounded failure falls
    # through to the explorer fallback below; an unbounded one never does.
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $wmiArgs `
      -OperationTimeoutSec 20 -ErrorAction Stop
    $created = [int]$result.ProcessId
    Log ('try ' + $attempt + ' wmi rv=' + $result.ReturnValue + ' pid=' + $created)
    if ($result.ReturnValue -eq 0 -and $created -gt 0) { return @{ pid = $created; via = 'wmi' } }
    Log ('try ' + $attempt + ' wmi refused (rv=' + $result.ReturnValue + ')')
  } catch {
    Log ('try ' + $attempt + ' wmi threw: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
  }
  try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $exe + '"' + $suffix) -ErrorAction Stop
    Log ('try ' + $attempt + ' explorer fallback issued')
    return @{ pid = 0; via = 'explorer' }
  } catch {
    Log ('try ' + $attempt + ' explorer threw: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
  }
  try {
    $taskName = 'dsh-power-restart-once'
    $taskCmd = ('"' + $exe + '"' + $suffix)
    $null = & schtasks.exe /create /tn $taskName /tr $taskCmd /sc once /st 00:00 /f 2>&1
    $null = & schtasks.exe /run /tn $taskName 2>&1
    # Delete the registration right after the run was issued: the task object is not
    # needed anymore (the process it started is independent), and leaving it behind
    # littered the scheduler with a stale "dsh-power-restart-once" forever.
    $null = & schtasks.exe /delete /tn $taskName /f 2>&1
    Log ('try ' + $attempt + ' schtasks fallback issued (task deleted after run)')
    return @{ pid = 0; via = 'schtasks' }
  } catch {
    Log ('try ' + $attempt + ' schtasks threw: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
  }
  return @{ pid = 0; via = 'none' }
}

$ExePath = Resolve-ExePath $ExePath
$script:StartedAt = (Get-Date).ToUniversalTime().ToString('o')

Log ('=== start reason=' + $Reason + ' process=' + $ProcessName + ' port=' + $Port + ' dryRun=' + [bool]$DryRun)
Log ('exe=' + $ExePath)
Write-Status 'start' 'running'

if ($DryRun) {
  $probe = Resolve-TargetIds $ProcessName $HostPid
  Log ('dry-run: mode=' + $probe.mode + ' would stop pids=' + ($probe.targets -join ','))
  Log ('dry-run: port free=' + (Test-PortFree $Port) + ' health=' + (Test-Health $Port))
  Log ('dry-run: foreign (same-named, not in our batch)=' + ((Get-ForeignIds $ProcessName @($probe.targets)) -join ','))
  Log 'dry-run: no action taken'
  Write-Status 'dry-run' 'ok' @{ targets = @($probe.targets); mode = $probe.mode }
  exit 0
}

# step 0: mutex - only one restarter at a time
$mutex = New-Object System.Threading.Mutex($false, 'Global\dsh-power-restart')
$owned = $false
try {
  $owned = $mutex.WaitOne(0)
} catch {
  Log ('mutex error: ' + $_.Exception.Message)
  $owned = $false
}
if (-not $owned) {
  Log 'skip: another restart is already in flight'
  exit 0
}
Log 'mutex acquired'

$script:MutexReleased = $false
function Release-Mutex {
  if ($script:MutexReleased) { return }
  try { if ($owned) { $null = $mutex.ReleaseMutex() } } catch { }
  try { $mutex.Dispose() } catch { }
  $script:MutexReleased = $true
  Log 'mutex released'
}

# Outcome of the main body. The watch (note 10) runs AFTER the mutex is released, so the
# success path must not exit inside the try - it would skip the watch entirely.
$script:FinalCode = 2

try {
  # step 1: decide whose pids to stop. Multi-instance safe: only OUR tree (our Electron
  # shell + its same-named descendants), never another instance's shell.
  $plan = Resolve-TargetIds $ProcessName $HostPid
  Log ('step1 mode=' + $plan.mode)
  if ($plan.mode -eq 'aborted') {
    Log 'abort: cannot identify our own process tree; refusing to kill all named pids'
    Write-Status 'stopping' 'aborted' @{ error = 'own-tree empty' }
    exit 1
  }
  $targets = @($plan.targets)
  if ($targets.Count -eq 0) {
    Log 'abort: empty target list'
    Write-Status 'stopping' 'aborted' @{ error = 'no targets' }
    exit 1
  }
  Log ('step1 targets=' + ($targets -join ','))
  Write-Status 'stopping' 'running' @{ targets = @($targets); mode = $plan.mode }

  # The clock for every "is this process ours?" question. Set BEFORE the first kill: any
  # same-named process with a later start time was spawned by our dying shell (a respawn)
  # or by our own relaunch, never by an instance that was already running. No slack here -
  # a wide margin would make another instance's in-flight boot look like ours and get it
  # killed, which is the one thing this plugin must never do.
  $script:KillStartedAt = Get-Date

  foreach ($procId in $targets) {
    try {
      Stop-Process -Id $procId -Force -ErrorAction Stop
      Log ('  stopped pid=' + $procId)
    } catch {
      Log ('  stop pid=' + $procId + ' failed: ' + $_.Exception.Message)
    }
  }

  # step 2: confirm that batch of pids is really gone
  $gone = $false
  $deadline = (Get-Date).AddSeconds($WaitClosedSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $alive = @($targets | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) { $gone = $true; break }
  }
  Log ('step2 confirmed-closed=' + $gone)
  if (-not $gone) {
    Log 'abort: some target pids are still alive'
    Write-Status 'stopping' 'failed' @{ error = 'target pids still alive'; targets = @($targets) }
    exit 1
  }

  # step 2b: SETTLE - hunt down what the kill resurrected.
  #
  # $targets is a snapshot. The shell supervises the host and re-spawns it, so killing the
  # host can produce a brand new process whose pid was never in the list. Step 2 cannot see
  # it (it only checks the listed pids), so 0.6.0 happily logged confirmed-closed=true and
  # then launched into a live instance: the launch was a stub, and each stub cost a 30-second
  # poll. Anything young and same-named is, by the clock above, OUR respawn - so kill it and
  # re-check until the field is quiet or the budget runs out.
  #
  # A second DSH instance the user starts by hand inside this window would look young and
  # get killed. That is the accepted trade: the window is short, it is our own instance's
  # respawn we are chasing, and the alternative (never killing respawns) is the 92-second bug.
  $respawns = @()
  $settleDeadline = (Get-Date).AddSeconds(6)
  while ((Get-Date) -lt $settleDeadline) {
    $young = @(Get-YoungForeignIds $ProcessName $targets)
    if ($young.Count -eq 0) { break }
    foreach ($procId in $young) {
      Log ('  respawn pid=' + $procId + ' (shell re-spawned after the kill); stopping it')
      try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {
        Log ('  stop respawn pid=' + $procId + ' failed: ' + $_.Exception.Message)
      }
    }
    $respawns += $young
    # give the OS a beat, then look again: a respawn can itself be re-spawned
    Start-Sleep -Milliseconds 300
  }
  $stillYoung = @(Get-YoungForeignIds $ProcessName $targets)
  if ($respawns.Count -gt 0) { Log ('step2b respawns stopped=' + (($respawns | Sort-Object -Unique) -join ',')) }
  Log ('step2b settled=' + ($stillYoung.Count -eq 0))
  if ($stillYoung.Count -gt 0) {
    # Still something of ours alive after chasing respawns. Launching now is how 0.6.0 got
    # its stubs, so refuse rather than burn the start budget on a no-op.
    Log ('abort: same-named processes we cannot account for are still alive (' + ($stillYoung -join ',') + ')')
    Write-Status 'stopping' 'failed' @{ error = 'respawns survived'; survivors = @($stillYoung); targets = @($targets) }
    exit 1
  }

  Write-Status 'stopped' 'running' @{ targets = @($targets); respawns = @($respawns | Sort-Object -Unique) }

  # Shutdown shares the mutex, the kill and the logging with restart; it just stops here.
  # Doing it in one script is what keeps "shutdown" and "restart" from drifting apart.
  if ($ShutdownOnly) {
    Log 'shutdown-only: all targets stopped, not relaunching'
    Log 'result: OK'
    Write-Status 'done' 'ok'
    exit 0
  }

  # step 2c: the port must be free before we relaunch, otherwise the new instance binds
  # a socket the OS has not released yet and dies with EADDRINUSE.
  if ($Port -gt 0) {
    $portDeadline = (Get-Date).AddSeconds($WaitPortSeconds)
    while ((Get-Date) -lt $portDeadline) {
      if (Test-PortFree $Port) { break }
      Start-Sleep -Milliseconds 200
    }
    $portFree = Test-PortFree $Port
    Log ('step2c port-free=' + $portFree)
    if (-not $portFree) {
      Log ('abort: port ' + $Port + ' is still in use')
      Write-Status 'port' 'failed' @{ error = 'port still in use'; targets = @($targets) }
      exit 1
    }
  }

  if (-not (Test-Path -LiteralPath $ExePath)) {
    Log ('abort: exe not found: ' + $ExePath)
    Write-Status 'launch' 'failed' @{ error = 'exe not found'; targets = @($targets) }
    exit 1
  }
  # Split-Path -LiteralPath returns nothing on this Windows PowerShell build; use .NET.
  $exeDir = [System.IO.Path]::GetDirectoryName($ExePath)
  Log ('step2b exeDir=' + $exeDir)

  # 0.6.0 had a hardcoded Start-Sleep -Seconds 2 here for no recorded reason. The port and
  # the pid batch are already verified above, so it only added two seconds to the critical
  # path. Removed.

  # step 3 + 4: launch outside the host's job, then confirm it came up. ONE shared budget
  # (not per attempt) plus the stub check. Verdicts: up | stub | booting | timeout | alive.
  $startDeadline = (Get-Date).AddSeconds($WaitStartSeconds)
  $attempt = 0
  $verdict = 'timeout'
  $newPid = 0
  $via = 'none'
  $ready = $false

  while ($attempt -lt $StartTries) {
    if ((Get-Date) -ge $startDeadline) { break }
    $attempt += 1

    # Note 9: never fire while ONE OF OUR OWN boots is still in flight. Young = started
    # after we began killing, so a second instance the user keeps running is NOT counted
    # here (that is what makes retries work on a multi-instance machine).
    $young = @(Get-YoungForeignIds $ProcessName $targets)
    if ($young.Count -gt 0) {
      Log ('try ' + $attempt + ' our own boot in flight (' + ($young -join ',') + '); waiting instead of stacking a launch')
      $holdDeadline = (Get-Date).AddSeconds(3)
      while ((Get-Date) -lt $holdDeadline -and (Get-Date) -lt $startDeadline) {
        Start-Sleep -Milliseconds 250
        if (Test-InstanceUp $Port $targets $ProcessName) { break }
        if ((@(Get-YoungForeignIds $ProcessName $targets)).Count -eq 0) { break }
      }
      if (Test-InstanceUp $Port $targets $ProcessName) { $ready = $true; $verdict = 'up'; break }
      if ((@(Get-YoungForeignIds $ProcessName $targets)).Count -gt 0) { continue }
      # our boot cleared without serving: fall through and launch again
    }

    $launch = Invoke-Launch $ExePath $exeDir $attempt $LaunchArgs
    $newPid = [int]$launch.pid
    $via = [string]$launch.via
    # Remember when this launch happened: with no port to probe there is nothing to poll for,
    # so the loop below uses this to stop as soon as the pid has outlived its first seconds.
    $launchAt = Get-Date
    if ($via -eq 'none') {
      Log ('try ' + $attempt + ' every launch path failed')
      Start-Sleep -Milliseconds 300
      continue
    }

    # Watch THIS launch. Three failure shapes:
    #   stub           - WMI gave us a pid; that pid quit itself and nothing of ours is
    #                    booting. Another, older instance holds the single-instance lock;
    #                    naming it beats burning the budget on retries of the same no-op.
    #   launch-failed  - explorer/schtasks paths give no pid at all. If, after a short
    #                    grace, NOTHING same-named has started and the port is silent, the
    #                    launch simply did not happen. 0.6.0 (and the first cut of this
    #                    rewrite) sat in 'waiting' until the whole budget expired instead
    #                    of declaring this dead in ~6s and firing again.
    #   timeout        - the budget expired while something was genuinely booting.
    $noPidGrace = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $startDeadline) {
      Start-Sleep -Milliseconds $LaunchPollMs
      $serving = Test-InstanceUp $Port $targets $ProcessName
      $alive2 = $false
      if ($newPid -gt 0) { $alive2 = Test-PidAlive $newPid }
      # No port to probe (Port 0, hand-run): polling to the end of the budget proves nothing
      # that "our pid is still alive two seconds in" does not already prove, and it is the
      # only evidence available. Stop here; the no-port fallback below turns it into ready.
      if ($Port -le 0 -and $alive2 -and ((Get-Date) - $launchAt).TotalSeconds -ge 2) { break }
      # Only OUR OWN young processes count as "still booting"; a pre-existing other
      # instance must not make us wait forever for a boot that will never be ours.
      $youngCount = (@(Get-YoungForeignIds $ProcessName $targets)).Count
      $verdict = Get-LaunchVerdict ([bool]$serving) ([bool]$alive2) ([bool]($newPid -gt 0)) ([int]$youngCount)
      if ($verdict -eq 'waiting' -and $newPid -le 0 -and $youngCount -eq 0 -and (Get-Date) -gt $noPidGrace) {
        $verdict = 'launch-failed'
      }
      if ($verdict -eq 'up') { $ready = $true; break }
      if ($verdict -eq 'stub') {
        # Our launched pid quit itself and nothing of ours is booting. If a same-named
        # process that predates our kill is alive it owns the single-instance lock: every
        # retry would stub the same way, so stop and name the blocker instead of burning
        # the remaining attempts on a no-op.
        $blockers = @(Get-ForeignIds $ProcessName $targets)
        if ($blockers.Count -gt 0) {
          $verdict = 'lock-held-by-other'
          Log ('try ' + $attempt + ' STUB against live process ' + ($blockers -join ',') + ' (predates our kill; it owns the single-instance lock); not retrying')
          break
        }
        Log ('try ' + $attempt + ' STUB: pid=' + $newPid + ' quit itself (lock owner gone mid-handshake?); spent=' + [math]::Round($script:Sw.Elapsed.TotalSeconds, 1) + 's not 30s')
        break
      }
      if ($verdict -eq 'launch-failed') {
        Log ('try ' + $attempt + ' LAUNCH-FAILED: no process of ours started via ' + $via + ' within the grace; declaring dead and retrying')
        break
      }
      # 'waiting' keeps polling, 'booting' means a process of ours that we did not launch
      # (a respawn during the settle window, or a child) is live - do NOT stack another
      # launch (note 9), keep probing the port.
    }
    if ($ready) { break }
    if ($verdict -ne 'stub' -and $verdict -ne 'launch-failed') { break }
    # stub or a dead launch -> tiny backoff, then fire again inside the shared budget
    Start-Sleep -Milliseconds 300
  }

  # Without a port to probe (Port 0, hand-run) fall back to "the pid we launched lives".
  if (-not $ready -and $Port -le 0 -and $newPid -gt 0 -and (Test-PidAlive $newPid)) {
    $ready = $true
    $verdict = 'alive-no-port'
  }

  # Which pid the port actually named is the one fact a "yes, it is up" claim should carry:
  # it distinguishes the instance we launched from an older one that merely answers on the
  # same port, and it is what the foreground/watch steps (and any later triage) needs.
  $servingPid = 0
  if ($ready) {
    if ($newPid -gt 0) { Log ('step3 relaunched pid=' + $newPid + ' via=' + $via + ' attempts=' + $attempt) }
    else { Log ('step3 relaunched via=' + $via + ' (detected on the port; pid not reported by this launch path)') }
    if ($Port -gt 0) {
      try { $servingPid = [int](Get-InstanceStatus $Port).pid } catch { $servingPid = 0 }
      if ($servingPid -gt 0) { Log ('step3b instance serving on port ' + $Port + ' host-pid=' + $servingPid) }
      else { Log ('step3b instance serving on port ' + $Port + ' (host pid not reported)') }
    } else {
      Log ('step3b no port to probe (Port=0); launched pid alive=' + [bool](Test-PidAlive $newPid))
    }
    # step 5: the user judges "restart finished" by seeing the window; a WMI-launched
    # process never gets the foreground on its own, so push it there.
    $fg = Bring-NewInstanceToFront $ProcessName $newPid $targets
    Log ('step5 foreground=' + $fg)
    Log ('step4 confirmed-started=true elapsed=' + [math]::Round($script:Sw.Elapsed.TotalSeconds, 1) + 's verdict=' + $verdict)
    Write-Status 'ready' 'ok' @{ newPid = $newPid; servingPid = $servingPid; via = $via; attempts = $attempt; targets = @($targets); foreground = $fg; verdict = $verdict }
    Log 'result: OK'
    $script:FinalCode = 0
  } else {
    Log ('step4 confirmed-started=false verdict=' + $verdict + ' attempts=' + $attempt)
    $heldBy = @(Get-ForeignIds $ProcessName $targets)
    $youngBy = @(Get-YoungForeignIds $ProcessName $targets)
    $why = $verdict
    # Attribute the failure precisely: OUR boot that never served, someone ELSE's lock,
    # or a bare timeout. "lock-held-by-other" must not absorb our own respawns - telling
    # the user to close an instance they are not running would send them down the wrong path.
    if ($youngBy.Count -gt 0) { $why = 'our-boot-not-serving' }
    elseif ($heldBy.Count -gt 0) { $why = 'lock-held-by-other' }
    Log 'result: FAILED'
    Write-Status 'launch' 'failed' @{ error = $why; attempts = $attempt; targets = @($targets); heldBy = @($heldBy); young = @($youngBy); via = $via }
    $script:FinalCode = 2
  }
} finally {
  Release-Mutex
}

# step 6 (note 10): confirm the claim by watching. Runs OUTSIDE the mutex on purpose: a
# human or the UI issuing a follow-up restart must never be blocked by our observation, and
# a teardown we see here is exactly the case 0.6.0 reported as success and then lost.
if ($script:Stage -eq 'ready' -and $WatchAfterReadySeconds -gt 0) {
  $watchUntil = (Get-Date).AddSeconds($WatchAfterReadySeconds)
  $baseline = $newPid
  if ($Port -gt 0) {
    try { $baseline = [int](Get-InstanceStatus $Port).pid } catch { $baseline = 0 }
  }
  Log ('watch: ' + $WatchAfterReadySeconds + 's, host pid=' + $baseline)
  $watchResult = 'ok'
  $watchNote = 'stayed up for ' + $WatchAfterReadySeconds + 's'
  while ((Get-Date) -lt $watchUntil) {
    Start-Sleep -Milliseconds 1000
    if ($Port -le 0) {
      # No port exists in this mode (hand-run), so the pid we launched is the only thing to
      # watch. Probing the status route here returned $null and made a healthy relaunch look
      # like 'teardown' with exit code 3 - a false failure out of the success path.
      if (-not (Test-PidAlive $newPid)) {
        $watchResult = 'died'
        $watchNote = 'launched pid ' + $newPid + ' is gone at +' + ([int]$script:Sw.Elapsed.TotalSeconds) + 's'
        break
      }
      continue
    }
    $status = Get-InstanceStatus $Port
    if ($null -eq $status -or $status.ok -ne $true) {
      # Count only OUR processes. A second instance the user keeps running is alive but is
      # not ours, and treating it as "our instance is still up" would hide a real failure.
      $still = @(Get-YoungForeignIds $ProcessName $targets)
      if ($still.Count -eq 0) {
        $watchResult = 'died'
        $watchNote = 'stopped answering and no process of ours is left, at +' + ([int]$script:Sw.Elapsed.TotalSeconds) + 's'
      } else {
        $watchResult = 'teardown'
        $watchNote = 'stopped answering but ' + $still.Count + ' of our pid(s) remain (' + ($still -join ',') + ') at +' + ([int]$script:Sw.Elapsed.TotalSeconds) + 's - looks like a restart this helper did not issue'
      }
      break
    }
    $currentPid = [int]$status.pid
    if ($baseline -gt 0 -and $currentPid -ne $baseline) {
      $watchResult = 'replaced'
      $watchNote = 'host pid changed ' + $baseline + ' -> ' + $currentPid + ' at +' + ([int]$script:Sw.Elapsed.TotalSeconds) + 's without this helper launching anything'
      break
    }
  }
  if ($watchResult -ne 'ok') {
    Log ('watch: ' + $watchNote)
    Write-Status 'watch' $watchResult @{ readyHostPid = $baseline; note = $watchNote }
    $script:FinalCode = 3
  } else {
    Log ('watch: ' + $watchNote)
  }
}

exit $script:FinalCode
