# Unit test for Resolve-OwnTree (extracted verbatim from restart-dsh.ps1, with a fake
# link table): two DSH instances side by side; the tree from instance A's host must be
# exactly A's shell+children, never B's. ASCII only.
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Host ('log: ' + $m) }

# --- begin verbatim copy ---
function Resolve-OwnTree([int]$hostPid, [string]$name, $links) {
  if ($hostPid -le 0) { return @() }
  $leaf = ($name -replace '\.exe$', '')
  $byPid = @{}
  foreach ($row in $links) { $byPid[[int]$row.ProcessId] = $row }
  if (-not $byPid.ContainsKey($hostPid)) { return @() }
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
# --- end verbatim copy ---

function Row($procId, $ppid, $name) { return [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $ppid; Name = $name } }
$DSH = 'DeepSeek Harness.exe'

# instance A: shell 100 (parent=explorer 1) -> host 101 -> gpu 102, renderer 103
# instance B: shell 200 (parent=explorer 1) -> host 201 -> gpu 202
# noise:      explorer 1, console 300 (named differently), unrelated 301 named DSH but parent=services
$links = @(
  (Row 1 0 'explorer.exe'),
  (Row 100 1 $DSH), (Row 101 100 $DSH), (Row 102 101 $DSH), (Row 103 101 $DSH),
  (Row 200 1 $DSH), (Row 201 200 $DSH), (Row 202 201 $DSH),
  (Row 301 999 $DSH)
)

$fail = 0
function Assert-Set($actual, $expected, $label) {
  $a = @($actual | Sort-Object); $e = @($expected | Sort-Object)
  if (($a -join ',') -eq ($e -join ',')) { "PASS $label -> " + ($a -join ',') }
  else { $script:fail++; "FAIL $label actual=" + ($a -join ',') + ' expected=' + ($e -join ',') }
}

Assert-Set (Resolve-OwnTree 101 $DSH $links) @(100,101,102,103) 'A host pid -> whole A tree, not B'
Assert-Set (Resolve-OwnTree 201 $DSH $links) @(200,201,202)     'B host pid -> whole B tree, not A'
Assert-Set (Resolve-OwnTree 100 $DSH $links) @(100,101,102,103) 'A shell pid -> same A tree'
Assert-Set (Resolve-OwnTree 301 $DSH $links) @(301)             'orphan named pid -> itself only'
Assert-Set (Resolve-OwnTree 999 $DSH $links) @()                'unknown pid -> empty (aborts the kill)'
Assert-Set (Resolve-OwnTree 0 $DSH $links) @()                  'hostPid 0 -> empty'

# name given WITHOUT .exe (as the plugin passes it) must still match
Assert-Set (Resolve-OwnTree 101 'DeepSeek Harness' $links) @(100,101,102,103) 'name without .exe still matches'

if ($fail -eq 0) { 'ALL PASS'; exit 0 } else { "$fail FAILED"; exit 1 }
