# testbed — end-to-end runs of the restart engine

The restart engine is the risky half of this plugin: it stops a live app and is then the only
thing left that can bring it back. These tests exercise it against a **fake app**, so they
never touch your real DSH.

## What the fake app is

`FakeDsh.exe` is a **copy of `node.exe`** (not committed — it is ~90 MB). The engine matches
processes by name, so the fake has to look like a second install of DSH: same image name,
different directory. Create it once:

```powershell
Copy-Item (Get-Command node).Source .\FakeDsh.exe
# node is not on PATH (the DSH runtime ships its own):
Copy-Item "<DSH>\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" .\FakeDsh.exe
```

`fake-shell.cjs` plays the Electron shell: it takes a lock port (`--lock-port`), spawns
`fake-host.cjs` as its host child and respawns it when it dies. `fake-host.cjs` serves the
plugin's own `/api/dsh-power/status` shape on `--state-port`, so the engine's readiness check
gets a real answer. A second shell that cannot take the lock exits after ~90 ms — exactly the
stub the real app becomes.

## Tests

```powershell
pwsh -File testbed\run-test.ps1 -Scenario A      # plain restart
pwsh -File testbed\run-test.ps1 -Scenario B      # same again (state left over from A)
pwsh -File testbed\run-test.ps1 -Scenario C      # a second instance must survive untouched
pwsh -File testbed\noport-test.ps1               # hand-run mode (-Port 0, no status route)
```

They use ports 19501-19505 only and only ever kill processes named `FakeDsh` (`KillAllFake`
at the end of each run).

| Test | Proves |
| --- | --- |
| A | own-tree kill → port freed → WMI relaunch → the new instance is verified on the port → watched for 5s → exit 0 |
| B | the same with a status/state file already on disk (no stale-read assumption) |
| C | a second instance on its own ports is not killed, keeps serving, and the restart still succeeds |
| no-port | with no status route to probe: exit 0, `stage=ready`, `result=ok`, and the launched pid is watched instead of a port |

Output: `engine-<scenario>.log` / `engine-<scenario>.json` (gitignored) next to these scripts,
the `SCENARIO <x> => PASS|FAIL` (or `NOPORT TEST => PASS|FAIL`) verdict line, and the process
exit code.

## Run these outside a restricted shell

In a sandbox that denies WMI/CIM (`CimException: 拒绝访问`) the engine correctly falls back to
`explorer.exe`, and a healthy run then looks like a failure — scenario A would fail for a
reason that has nothing to do with the code under test. Use a normal shell.