# Validation Report

Date: 2026-10-02
Version: 1.1.1

## Automated result

The current worktree passed:

```text
Bash syntax:                 PASS
Function-role comment lint:  PASS
Version consistency:         PASS (keepalive + 4 documents + CHANGELOG)
Test files:                  31 / 31 PASS
Assertions:                  1519 / 1519 PASS (1 ownership case skips when not run as root)
systemd-analyze verify:      PASS
Installer layout simulation: PASS (non-root + mocked systemctl)
Installer lifecycle/rollback: PASS (stateful mocked systemctl + injected activation failure)
Portable runtime/IPC errors: PASS (unsafe paths, D-Bus escaping, write/lock failures)
Daemon/client integration:   PASS (real Bash processes/FIFO + mocked qdbus and Orca CLI)
Live Orca read-only adapter: PASS (discovery + exact terminal-show identity validation)
ShellCheck:                  PASS (container; no findings beyond the pre-existing test-mock notes)
Resource benchmark:          PASS (isolated before/after; see CHANGELOG "Performance")
```

Run the same aggregate command with:

```bash
./scripts/dev-check.sh
```

## High-value scenarios validated

- Literal message strings containing shell metacharacters remain data and are never executed.
- Scalar files without trailing newlines are read correctly.
- Profile updates do not require sourcing configuration.
- Main-message requests must be contiguous non-empty `001..N` rotations; malformed CREATE/CONFIGURE data is rejected before target/profile mutation.
- Claude/Gemini/Aider wrapper signatures are recognized while an ordinary shell remains unclassified.
- Mocked Konsole discovery records the expected `shellSessionId`, service, path, and PID.
- Strict identity validation rejects a different session UUID.
- Mocked Orca discovery excludes ordinary shell terminals and records the exact runtime,
  handle, PTY, incarnation, worktree, execution-host, tab, leaf, and agent binding.
- Orca text plus Enter uses one atomic terminal-send request.
- An Orca-only daemon starts with Konsole disabled and supports discovery, CREATE, manual
  delivery, transient runtime outage, and sticky terminal-incarnation replacement across
  the real FIFO/client process boundary.
- Missing or changed Orca JSON fields fail closed. Repeated unsupported-schema validation
  blocks delivery without consuming reachability strikes or making identity sticky.
- Konsole and Orca discovery snapshots commit independently; one incomplete backend pass
  cannot erase the other backend's rows.
- Checkpoints without a backend remain compatible as Konsole, while unknown backends and
  runtime/incarnation rebinding are rejected before recovery.
- Multiple client request IDs can traverse the same FIFO and receive independent responses.
- A real background service process can be controlled by a separate public `keepalive` client process.
- CREATE crosses the real FIFO/request-directory boundary and produces ACTIVE target state.
- Manual MAIN sends cross daemon IPC and invoke mocked Konsole `sendText`.
- Main and secondary transport failures return failure after logging/checkpointing while preserving the defined timer and rotation semantics.
- A mocked qdbus transport failure crosses the real daemon/FIFO boundary as `ERROR`, not a false success.
- MESSAGE+ENTER advances rotation; ENTER_ONLY does not consume the queued message.
- Secondary sends preserve the main remaining timer.
- Large scheduler gaps preserve both timers.
- An injectable monotonic source is parsed safely; backward readings preserve countdowns and reset cadence rather than freezing work.
- Hung qdbus calls terminate at their configured deadline, return IPC failure, and do not turn a valid target sticky UNAVAILABLE.
- Hung optional notification helpers terminate at their configured deadline without failing keep-alive work.
- Same-login daemon recovery preserves main/secondary remaining time.
- Recovery accepts fully valid checkpoints but quarantines malformed fields, out-of-range timers, UUID/path mismatches, missing files, broken rotations, and symlinked records/messages.
- Quarantine records retain a precise rejection reason and preserve matching event logs without following rejected symlinks.
- AI process loss becomes sticky UNAVAILABLE.
- An old unavailable Avela UUID and a new same-directory Avela UUID coexist as separate UNAVAILABLE/AVAILABLE records; no auto-reattach occurs.
- Delete removes only keep-alive runtime state/history.
- `--no-icons`/ASCII timer primitives remain semantically readable.
- First TUI draw, renderer transitions, and terminal resize clear the visible screen while same-view refresh avoids repeated full erases.
- Every frame is sized from live terminal width: verified across 15 widths from 52 to 200 columns, three target states, and four presentation modes with no line exceeding the terminal.
- Truncation never overruns: non-positive derived widths yield nothing instead of printing the untruncated string.
- Control bytes in messages, directories, and process labels are stripped before reaching the screen.
- Index rows decode faithfully, including empty columns that Bash `read` would otherwise collapse.
- `--ascii` renders a fully 7-bit interface, frame glyphs included, not only ASCII progress bars.
- Colored segment headers degrade to plain boxed headers when color is unavailable or the bar would not fit.
- Only a bare `Esc` cancels: arrows, function keys, keypad keys, and bracketed-paste markers are ignored rather than exiting the client.
- A key typed immediately after `Esc` is preserved rather than swallowed.
- A cancelled wizard or a rejected daemon action returns to the previous screen instead of terminating the client.
- Client scratch directories and index sort files do not survive an interrupted TUI.
- Wizard input is returned out of band, so custom messages and intervals are stored verbatim instead of being contaminated by prompt text and cursor escapes.
- Wizard steps render the shared colored segment header with step progress, degrading to the boxed header without color and to a 7-bit frame under `--ascii`.
- Daemon refusals reach the client with their specific reason, on both the CLI and the TUI.
- A D-Bus call that could not be made is transient and debounced; only a completed call returning a different value, or local `/proc` evidence, marks a target UNAVAILABLE.
- Periodic health validation reuses the discovery snapshot and issues no D-Bus call for an already-discovered target, while pre-send validation stays live.
- The public CLI drives the whole lifecycle: create, configure, pause, idempotent pause, resume, delete, and `list --json` validated by a real JSON parser; `configure` validates intervals in `1..999999999` and supports explicit profile policy.
- `status --json` reads only validated snapshots, is presence-free, does not activate IPC or create HOME/configuration state, and matches `pid_start` before reporting a service online.
- Published index rows retain columns 1-15 and append next-send/last-delivery columns 16-21; automatic `ENTER_ONLY` and one-shot Enter events are logged as `ENTER`.
- Pending-submit ownership survives reload, maps legacy persisted `1` to `MAIN`, and CONFIGURE commits a `STALE` owner before replacing message files.
- Event logs are trimmed to a retention budget and repeated scheduler-gap events collapse to one entry per episode.
- Every drawn TUI line erases its own tail, so a frame that changes height cannot leave the previous line's text beside the new one.
- One discovery pass is time-bounded; a truncated pass retains the previous snapshot instead of publishing a partial one.
- A message delivered without its submit is completed on the next attempt rather than re-sent, and the event log records that state.
- Main rotations and message lengths are bounded, and all control characters are stripped from untrusted labels.
- The predictable /tmp runtime fallback is refused when it is a symlink or not owned by this user.
- Message-directory replacement commits through a staged swap that rolls back on failure, with abandoned staging directories swept at startup.
- Re-running the installer restarts an already active daemon so clients never talk to stale sourced code.
- A pseudo-terminal test drives the real client, and a small VT emulator renders the capture so stale-tail defects are visible to the suite.
- Detail-view `e` sends a single Enter and returns the target to MESSAGE+ENTER without consuming a queued message; `E` pins ENTER ONLY.
- The secondary prompt fires automatically once per arming and re-arms only on reconfiguration, while manual secondary sends stay available.
- Checkpoints written before `secondary_done` existed still load and default to not-yet-sent.
- No `local` declaration reads a name it defines in the same statement, which bash expands before creating any of them.
- A client outside a PAM session still finds the daemon: the runtime base falls back to `/run/user/$UID` before `/tmp`, and `doctor` names the rule that chose it.
- A control FIFO left behind by a killed daemon times out the client instead of blocking it forever.
- A failing periodic daemon task warns and continues rather than aborting the daemon into a systemd restart loop.
- A vanished runtime directory ends the daemon cleanly, and lock contention exits successfully instead of being retried.
- A timer event is consumed and checkpointed before delivery, so a crash between sending and checkpointing cannot repeat it.
- An unreachable daemon reports a reason rather than an empty one.
- An invalid tuning knob warns once and falls back to its default, instead of aborting the daemon or silently disabling the work it guards.
- The control read distinguishes an idle timeout from a broken descriptor, so a degenerate read cannot become a busy spin.
- A repeated clock-read failure warns once per episode rather than several times a second.
- A target whose message files are missing stays usable and is told to reconfigure, rather than becoming an unrecoverable UNAVAILABLE record.
- Classifier entries with CRLF endings load correctly, and a pattern that cannot compile is refused with the offending line named.
- Discovery backs off on client presence alone, so a monitored target no longer pins it to the fast cadence forever.
- Health validation refuses a discovery snapshot older than its permitted age and falls back to a live check.
- A countdown decrement marks a target dirty rather than rewriting its whole checkpoint every tick.
- User installer places source, symlink, and systemd units correctly and enables the socket entrypoint.
- Socket activation is installed under `sockets.target`; the service is static and bound
  to the socket without any KDE or `graphical-session.target` dependency.
- Upgrades stage the full source tree, work when launched from the installed copy, remove
  obsolete graphical target links, restart an active daemon, and restore source, units,
  command link, and prior systemd enable/active state after an injected activation failure.
- Manager-scoped `XDG_CONFIG_HOME` placement rejects a mismatched shell before writes and
  canonicalizes trailing-slash/symlink aliases so legacy cleanup cannot delete new units.
- Relative, foreign-owned, and parent-symlink runtime paths are rejected; a safe
  `/run/user/$UID` remains available to SSH/non-PAM clients, and derived D-Bus addresses
  percent-escape reserved and UTF-8 bytes.
- Scalar destination directories, FIFO writes, response writes, lock setup, and failed
  CLI-create setup all return errors instead of being masked by later successful cleanup.
- `keepalive.socket` and `keepalive.service` pass `systemd-analyze verify`.

## Live workstation evidence for 1.1.0

Measured on the development host (Parrot, systemd 257) on 2026-10-01 with the release
installed through `./scripts/install.sh`, the daemon socket-activated by the real user
manager, managing one live Orca keep-alive (Konsole service present, no Konsole target).

| Check | Observed |
|---|---|
| Install over a running 1.0.0 daemon | `Reloaded 1 running keep-alive(s) on the updated daemon.`; countdown carried over |
| Second in-place update (control-read fix) | Reloaded again; countdown 1422 s -> 1416 s across the restart |
| Unit scheduling on the live process | nice 10, `SCHED_BATCH`, idle I/O class, `KillMode=mixed`; timer slack configured (not readable from `/proc` unprivileged) |
| `keepalive doctor` | All critical checks pass; Konsole and Orca both usable; Orca runtime READY |
| Control requests after the fix | `status` 40/40, `refresh` 30/30, slowest refresh 619 ms |

Daemon cost on the same machine, 60 s cgroup samples, one ACTIVE Orca target, no client:

| | 1.0.0 | 1.1.0 |
|---|---:|---:|
| CPU | 7.41% | **1.21%** |
| Voluntary wakeups per minute | 586 | **95** |
| RSS | 8.5 MiB | 9.4 MiB |

Not exercised live for this release: a non-KDE systemd user session, and Konsole delivery
(the live Konsole service had no monitored target). Those paths are covered by the mocked
suite and the unchanged 1.0.0 live evidence below.

## Live workstation evidence for 1.0.0

Measured on the target KDE/Parrot workstation on 2026-08-23 against a live Plasma
session, a live Konsole user D-Bus, and the installed daemon managing two real Claude
Code sessions.

### Recovery

| Scenario | Expected | Observed |
|---|---|---|
| `systemctl --user restart` | Countdowns lose only the restart gap | Both targets lost exactly the 3 s gap (14:48 to 14:45, 02:02 to 01:59) |
| `kill -9` on the daemon | systemd restarts it; countdown resumes at most one checkpoint interval stale | Restarted automatically; countdowns resumed 2 s stale; `quarantine/` empty; no journal warnings |

Both targets recovered from checkpoints in each case without being recreated.

### Daemon CPU

Two active targets, sampled on one core:

| State | Before this release | 1.0.0 |
|---|---:|---:|
| Client attached | 36.4% | **20.7%** |
| Unattended | 38.4% | **7.5%** |

Component timings behind that:

| Operation | Before | 1.0.0 |
|---|---:|---:|
| `ka_state_save_target` | 14.75 ms | 5.00 ms |
| `ka_state_publish_index` | 12.25 ms | 4.25 ms |
| `ka_scheduler_tick` (2 targets) | 32.50 ms | 11.00 ms |

One measurement caveat worth recording, because it invalidated several earlier readings:
six orphaned daemons from ad-hoc scripts without cleanup traps were running alongside the
real one, each polling at roughly 0.8%. Always confirm
`ps -eo args | grep '[k]eepalive --service'` returns exactly one process before profiling.

### Static and interface checks

- `keepalive doctor` reports all critical checks passing, naming `/run/user/1000 (xdg)` as
  the runtime source and finding 3 Konsole D-Bus services.
- Bash syntax clean across all 45 shell files.
- No stale command-substitution call sites remain for any of the nine helpers converted to
  return through `REPLY`.
- Both sites that read `REPLY` twice do so around a deliberate intervening re-set.

## Remaining live-host qualification gate

This report was produced **on the target KDE workstation**, against a live Plasma session, a live Konsole user D-Bus with 11 services and 16 sessions, and an installed daemon. Live discovery, `keepalive doctor`, `keepalive list`, unit verification, and pseudo-terminal TUI runs were all exercised there.

The following still require deliberate runtime qualification rather than being covered by automated claims:

1. live Konsole `sendText` injection into a real AI client (delivery is still mock-covered only);
2. process-tree shapes of every installed AI CLI beyond Claude;
3. systemd user socket activation under `sockets.target` from a cold non-KDE/headless
   login, including migration of an older graphical-session link;
4. KDE notification delivery;
5. Nerd Font glyph cell widths in the user's configured Konsole font, including the powerline caps and wedges;
6. real laptop suspend/resume lifecycle.
7. one harmless live send to a disposable Orca agent, including the returned acceptance receipt;
8. live Orca restart/terminal replacement behavior through the installed systemd daemon.

The complete live checklist is in `docs/MAINTENANCE.md`.

## Confidence statement

The implementation has high confidence for the designed Bash state machine, IPC, data
safety, timer semantics, backend-qualified no-reattach behavior, installer layout, and
daemon/client lifecycle exercised by the included tests. The installed Orca CLI's current
discovery and identity-read contract was verified read-only. Live delivery remains an
explicit final gate rather than treating a mocked acceptance receipt as proof.
