# dsh-power

Power actions for **DSH (DeepSeek Harness)** desktop profile: restart and shutdown via a draggable power card on the page.

## What it does

- A single draggable card on the DSH UI: left half = shut down, right half = restart; middle seam is safe.
- First click asks ("Shut down?" / "Restart?"). Second click on **any spot** executes that action (clicking elsewhere won't re-target).
- Escape / click outside / 3s timeout cancels with a brief "Cancelled" toast.
- `Shift+click` = dry-run only (checks endpoints without firing).
- Drag to move (saved in localStorage); double-click the middle seam resets position.

Behind the scenes:

- The new instance is launched outside the host's Job Object (WMI → explorer/scheduler fallback) and is only reported as up once it answers on `/api/dsh-power/status` with a pid that started **after** the kill — "something is listening" is not enough, because a second instance answers just as well.
- After it says OK the helper keeps watching for a while, outside the lock: if the instance dies, is torn down, or the serving pid changes without this helper launching anything, the recorded result is corrected instead of staying a false success.
- Retries are cut short when they cannot win: if an old instance still holds the single-instance lock the failure says `lock-held-by-other` instead of burning the whole budget, and a launch path that reported no pid at all is declared dead after ~6s and retried.
- If you have multiple DSH instances running, this version kills **only your current session tree** (parent + children whose path matches), avoiding killing another instance by accident.
- On restart, the new window is brought to the foreground so you can see that it finished.

## Requirements

- Windows 10/11 (PowerShell 5.1 for WMI and Win32 calls).
- DSH desktop profile (injected by the host process, no browser side needed).
- Node.js 20+ (whatever DSH ships is fine).

## Install

From GitHub (when available):

```sh
dsh plugin --profile desktop add github:nanshang328/dsh-power
```

Or from a local folder / ZIP download:

```sh
dsh plugin --profile desktop add ./dsh-power
```

Then restart DSH. The package declares `dsh.bundle`, so it mounts as a normal profile layer.

## Config

Plugin config (override the same id in your profile's `cordis.patch.yml`; a later patch
REPLACES the whole `config` object, so restate every key you still want):

```yaml
- id: dsh-power
  name: 'dsh-power'
  config:
    port: 0                # 0 = discover from webServer/--port
    processName: DeepSeek Harness
    exePath: ''            # '' = use process.execPath
    showRestart: true
    showShutdown: true
    confirmPower: true     # both actions need a second click (confirmShutdown is the old name, still read)
    confirmMs: 3000        # how long the pending question stays armed
    foreground: true       # bring the new window to the front after restart
    logToTemp: true        # write %TEMP%\dsh-power.log
```

## Security notes

- The power endpoints require `isLoopback` AND a custom `x-dsh-power: 1` header. A random
  web page cannot send that header cross-origin without a CORS preflight, which this route
  does not answer — so drive-by "shut down the user's app" from an ad iframe is blocked.
  (A `no-cors` fetch with only simple headers still reaches the server, which is exactly
  why the header check exists.)
- Multi-instance safety: with several DSH instances running, only the calling instance's
  process tree (its Electron shell + same-named descendants, resolved from the host pid)
  is stopped. Other instances are left alone. If the tree cannot be resolved the script
  aborts instead of falling back to "kill all named". `-KillAllNamed` restores the old
  behavior explicitly; `-Explain` prints both sets without killing anything.

## Known limitations

- No unsaved changes are preserved by any OS-level hook (that's expected).
- After a successful restart, the widget may momentarily say "request failed" — that's just the old instance dying mid-flight. Check logs or `/power-status` for confirmation.
- Some fully-focused games / video apps reject `SetForegroundWindow`; in that case logs will say `foreground=refused`.
- Position persistence is browser-scoped (localStorage); switching browsers changes where the card appears.
- Hand-run mode (`-Port 0`, when you run the script yourself) has no status route to probe: readiness there is "the pid we launched outlived its first seconds", and it is watched by pid liveness rather than by the port.

## Development

- Source: `lib/index.js` (host half), `client/widget.js` (the card), `scripts/restart-dsh.ps1`
  (the restart engine). `client/niang-sleep.webp` is inlined into the widget by
  `tools/embed-icon.cjs` (run `python tools/build-icon.py` first if you swap the art).
- The PowerShell script must stay **ASCII-only**: Windows PowerShell 5.1 reads a BOM-less
  `.ps1` as ANSI, and Chinese comments can swallow newlines and break the parser.
- Checks: `npm run check` (node --check on both JS files); `pwsh -File test/tree-test.ps1`
  (unit test for the multi-instance tree resolution against a fake process table);
  `pwsh -File testbed\run-test.ps1 -Scenario A|B|C` and `pwsh -File testbed\noport-test.ps1`
  (end-to-end runs of the engine against a fake app on ports 19501-19505 — they never touch
  the real DSH); `pwsh -File scripts/restart-dsh.ps1 -Explain -HostPid <pid>` (dry look at
  what a restart would kill on YOUR machine, kills nothing).
- Run the testbed in a normal, unrestricted shell. Inside a restricted sandbox WMI is denied
  (`CimException: 拒绝访问`), the launch legitimately falls back to explorer, and a healthy
  run then looks like a failure.
- Hot deploy while developing: copy the tree into
  `~/.dsh/profiles/desktop/plugins/dsh-power` and register it via
  `dsh plugin --profile desktop add <path>`. Widget changes need only a page refresh
  (the route re-reads the file per request); `lib/index.js` changes need a DSH restart;
  the `.ps1` is spawned fresh per action, so it is always live.

## History of design fixes (each one maps to a real failure)

1. Kill shell + host together — the Electron shell auto-restarts a killed host and races
   the helper for the web port (EADDRINUSE crash loop).
2. Launch via WMI (explorer/scheduler fallbacks) — a helper launched inside the host's Job
   Object dies with it, so the relaunch never happens.
3. Readiness = a real `/api/dsh-power/status` reply from a NEW pid, not "a pid exists".
4. CSRF header on the power endpoints (a plain cross-origin POST used to reach them).
5. Multi-instance safety: stop only our own process tree, resolved from the host pid.
6. Foreground push after restart, so a fullscreen game doesn't hide the result.
7. schtasks one-shot task deleted right after use (it used to linger forever).
8. Settle window after the kill: an Electron shell respawns its host, so a shell killed a
   moment too late left a young boot behind to race the new instance for the port. Same-named
   processes younger than the kill are now stopped too, then the port is waited out.
9. `lock-held-by-other` / `launch-failed` verdicts: retrying against a lock another instance
   owns can never succeed, and the explorer/schtasks paths can report no pid at all — both
   used to consume the entire start budget (30s per try) before saying anything.
10. Watch after "OK": readiness was a single observation, so an instance that died or was
    restarted a second later still left `ready/ok` in the status file. The helper now watches
    for a while (outside the lock) and rewrites the record as `died` / `teardown` / `replaced`.
11. Hand-run mode (`-Port 0`) no longer polls a budget it cannot satisfy and no longer reports
    a healthy relaunch as `teardown` with exit code 3 — it watches the pid it launched.
12. WMI calls carry a 20s operation timeout: this helper runs after the old instance is
    already dead, so a hung CIM call must fall through to the explorer fallback instead of
    leaving the app stopped with nobody left to relaunch it.
13. The status record carries `servingPid` (the host pid the port actually named), so "up"
    names the instance it verified instead of only the pid a launch path reported.

## License

MIT (copy of the pattern used by companion plugins).
