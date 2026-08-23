# Observed Risks, Gaps, and Open Questions

These notes distinguish implemented behavior from documented intent. Priorities
are suggested for future work, not claims that the product is unusable.

## Resolved on 2026-08-21: transport failures now propagate

`ka_scheduler_send_main` and `ka_scheduler_send_secondary` now retain the intended
event semantics—log/notify failure, reset only the consumed timer, checkpoint
state, and do not advance main rotation—while returning nonzero after a failed
`ka_konsole_deliver`. Manual daemon/FIFO callers therefore receive `ERROR` instead
of an incorrect `OK`.

Regression coverage includes main and secondary unit failures plus a real
background daemon/FIFO request whose qdbus mock is switched into failure mode.

## Resolved on 2026-08-21: request message rotations are canonical

Daemon-side profile validation now requires a non-empty contiguous sequence of
regular numbered message files beginning at `001`, with no gaps or empty slots.
Only three-digit numbered files are copied into profile and target state. Rejected
CREATE and CONFIGURE operations are tested to leave monitored target state and the
persistent profile unchanged.

## Resolved on 2026-08-21: scheduler uses monotonic time and handles rollback

The service loop now derives countdown and cadence elapsed time from integer
`/proc/uptime` readings rather than wall-clock epoch seconds. The source is
injectable for deterministic testing. A negative reading explicitly preserves all
countdowns, logs the anomaly, and resets timer/health/discovery/publication/cleanup
anchors so work cannot freeze while a clock catches up.

Regression coverage includes source parsing and negative scheduler movement.

## Resolved on 2026-08-21: external desktop helpers are deadline-bounded

Every qdbus subprocess and optional `notify-send` call now runs under GNU
`timeout`, with independent positive-integer overrides and a two-second default.
Validation timeouts have a dedicated transient status: health/recovery defer,
while a due/manual send fails its consumed event without making identity sticky
UNAVAILABLE. Delivery timeout remains a logged transport failure.

Coverage includes hung qdbus validation, hung notification execution, periodic and
recovery validation deferral, and a real daemon/FIFO timeout response.

## Resolved on 2026-08-21: recovery rejects and quarantines corrupt records

Runtime loading now validates the complete known checkpoint schema, duplicate and
extra columns, enums/booleans, numeric ranges, UUID/directory binding, Konsole
address shape, required secondary data, canonical rotation/index, and non-symlink
record/message paths before registering arrays. Invalid target entries move to a
unique runtime quarantine wrapper with a reason, timestamp, and matching event log.

Regression coverage restores a valid record while quarantining corrupt start time,
timer range, required-file, UUID binding, message rotation, message symlink, and
top-level target-symlink cases without following the latter.

## Resolved on 2026-08-22: `PrivateTmp=yes` no longer breaks session identity

`keepalive.service` set `PrivateTmp=yes`, which places the daemon in a private
mount namespace. `/proc/PID/cwd` and `/proc/PID/exe` are magic symlinks resolved
against the *reader's* mount namespace, so the daemon could not resolve either one
for AI processes it does not own, while `comm`, `cmdline`, and `stat` kept working.

Observed live on the workstation before the fix: every discovered row published
name `unknown` and directory `?`, making multiple concurrent Claude sessions
indistinguishable in the TUI, `keepalive list`, and `index.tsv`. The same discovery
code run outside the unit resolved the real project directories. `ka_proc_exe_basename`
also failed silently, dropping the exe component from `ka_proc_signature` so that a
wrapper recognizable only by executable basename would not classify.

Note that discovery, PID-reuse guarding, and foreground-ancestry validation were
never affected, because those read only `comm`, `cmdline`, and `stat`.

The unit now uses only namespace-free hardening (`NoNewPrivileges`,
`RestrictSUIDSGID`, `RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`,
`SystemCallArchitectures=native`, `RestrictAddressFamilies=AF_UNIX`), all verified
against live Konsole discovery. The unit carries a comment naming the specific
directives that must never be added back.

This also removes the service-namespace half of the `/tmp` fallback risk below.

## Resolved on 2026-08-22: transient D-Bus failures no longer destroy targets

`ka_konsole_validate_target` now returns a dedicated transient code 21, "Konsole D-Bus
session could not be reached", whenever a call cannot be made at all. Only a call that
completed and returned a different value, or a local `/proc` check, is treated as
identity loss. `ka_state_validate_targets` debounces transient results through
`KA_T_STRIKES`, giving up after `KEEPALIVE_VALIDATION_STRIKES` (default 5) consecutive
failures and recording the count in the reason. Strikes are runtime-only and reset on
any successful validation.

Original finding follows.

### Original finding: a transient D-Bus failure permanently loses every target

`ka_konsole_validate_target` treats only GNU `timeout` expiry (124/137) as transient.
Every other non-zero status from `ka_konsole_get` falls through to return 10,
"Konsole session UUID no longer matches", which is definitive and makes the record
stickily `UNAVAILABLE`.

Measured classification on the live bus:

```text
live service      -> ka_konsole_get rc=0
service not on bus -> ka_konsole_get rc=2  -> validate rc=10, transient=no
```

So a momentary session-bus outage, a Konsole restart, or `ka_qdbus_exec` returning
127 because qdbus or `timeout` is briefly unavailable marks *all* monitored targets
permanently unavailable. The user must then delete and recreate every keep-alive.

The asymmetry is backwards: a call that never completed is treated as proof of
identity loss, while a call that completed slowly is not. Only a call that
*succeeded and returned a different value* proves identity loss.

Recommended: separate "could not ask" from "asked and it differs". Give the former
its own transient code, and require N consecutive definite failures (a strike
counter) before a record becomes sticky, which also survives a Konsole restart.

## Resolved on 2026-08-22: refusal reasons reach the client

`ka_error` now records its message in `KA_LAST_ERROR`, `ka_ipc_handle_request` clears it
per request and returns it in place of the fixed string, and the scheduler sets it for
transport and validation failures. The operator sees the actual cause in the TUI toast
and on the CLI. Integration coverage asserts the specific strings rather than a generic
one, and a CLI test asserts the duplicate-create refusal text.

Original finding follows.

### Original finding: failed create/configure discards the reason

`ka_ipc_handle_request` replaces every failure with a fixed string:

```bash
CREATE) ka_state_create_target "$uuid" "$dir/config" || { rc=$?; message='could not create keep-alive'; }
```

The precise cause is written to the daemon's stderr and therefore only reaches the
journal. Reproduced end to end:

```text
daemon stderr : keepalive: ERROR: main message 002 must be one non-empty logical line
client sees   : ERROR<TAB>could not create keep-alive
```

This is not hypothetical. The workstation journal shows the operator hitting exactly
this on 2026-08-21 at 16:05 and 16:07, twice, with no actionable feedback in the UI:

```text
keepalive[2531567]: keepalive: ERROR: main message 001 must be one non-empty logical line
keepalive[2598424]: keepalive: ERROR: main message 002 must be one non-empty logical line
```

Recommended: capture validator output into the response `message`, and additionally
validate in the wizard before submitting so the common cases never reach the daemon.

## Resolved on 2026-08-22: daemon CPU reduced roughly fourfold

Measured on the review workstation, idle with no keep-alives and no client attached, at
the same Konsole session count: **19.20% of one core before, 4.77% after**.

What changed:

1. `dbus-send` is now the default transport for read-only calls, with `qdbus` retained
   as fallback and pinned whenever `KEEPALIVE_QDBUS` is set (which is how the suite
   injects its mock). Warmed, interleaved A/B through the real `ka_konsole_get` path:
   **12.50 ms to 4.67 ms CPU per call, a 2.4x speedup**. The isolated binary comparison
   is larger (9.7 ms vs 2.7 ms) because shared wrapper overhead does not shrink.
2. Periodic health validation now reuses the discovery snapshot via
   `ka_state_validate_from_discovery`, costing zero D-Bus calls for any target discovery
   already saw. Pre-send validation deliberately still uses the live path.
3. Discovery backs off to `KEEPALIVE_IDLE_DISCOVERY_INTERVAL` (default 30 s) when nothing
   is monitored and no client has touched `clients.seen` within
   `KEEPALIVE_CLIENT_PRESENCE_TTL` (default 20 s). The TUI refreshes that file once a
   second with a fork-free redirect.
4. `ka_now_monotonic` sets `REPLY`; the service loop read it through a command
   substitution five times a second.
5. `ka_atomic_write_value` writes literals with `printf` instead of a pipeline into
   `cat`, and permissions come from a `umask` set once in `ka_xdg_init` rather than a
   `chmod` fork per file. Scalar writes went from about five forks to one.
6. `service.state` is written every `KEEPALIVE_STATUS_INTERVAL` (default 15 s) rather
   than every second; it is diagnostics only, clients read the index.
7. `ka_dbus_timeout_resolve` sets the deadline in a variable instead of a command
   substitution per bounded call.

Two measurement traps worth remembering: a cold binary cache made `dbus-send` look
*slower* than `qdbus6` on first run, and an early attempt at the adaptive cadence put a
command substitution in the loop condition, which cost more than the polling it saved.
Always warm the binaries and measure the loop, not just the call.

Original finding follows.

### Original finding: qdbus process startup dominates daemon CPU

Previously recorded as "discovery cost scales with sessions". Measured decomposition
now shows the real driver is Qt process startup per call, not call count.

Per-call cost of one `shellSessionId` read, 25 iterations each:

| client | CPU per call | wall per call |
|---|---:|---:|
| `qdbus6` | 12.8 ms | 15.3 ms |
| `busctl` | 6.0 ms | 7.9 ms |
| `gdbus` | 5.6 ms | 7.5 ms |
| `dbus-send` | **2.4 ms** | 3.8 ms |

One discovery cycle with only 2 Konsole sessions costs 262 ms CPU, split:

```text
qdbus property reads   162 ms  (62%)
/proc classifier walk   76 ms  (29%)
remainder               24 ms   (9%)
```

Idle loop bookkeeping, 0 targets:

| operation | cost | rate | per second |
|---|---:|---:|---:|
| `now=$(ka_now_monotonic)` | 1.45 ms | 5/s | 7.25 ms |
| `ka_service_write_status` | 8.00 ms | 1/s | 8.00 ms |
| `ka_state_publish_index` | 3.10 ms | 1/s | 3.10 ms |
| discovery cycle | 262 ms | 1/3s | 87.3 ms |

Observed service totals: 13 h 45 min CPU over 24 h (57% of one core) with 11 services
and 16 sessions, then 3 h 02 min over 6 h 42 min (45%) after the unit fix, and 19.2%
measured over a 25 s window with 1 service and 2 sessions and zero keep-alives.

Ranked remedies, all independent:

1. Replace `qdbus6` with `dbus-send` for the read-only property calls: 5.3x cheaper,
   and it is already installed. Output parsing differs (`string "..."`), and service
   and object enumeration would still need introspection, so keep one `qdbus6` call
   per cycle for that or parse `Introspect` XML.
2. Stop duplicating work: `ka_konsole_discover` and `ka_konsole_validate_target` read
   the same three properties for the same sessions on 3 s and 2 s cadences. One shared
   pass would remove roughly 40% of the D-Bus calls whenever targets are monitored.
3. Back off discovery when nothing is monitored and no client has polled recently.
4. Make `ka_now_monotonic` set `REPLY` instead of being called in a command
   substitution five times a second.
5. Write `service.state` on change or every N seconds rather than every second, and
   avoid `ka_atomic_write`'s `mkdir`/`chmod`/`cat`/`mv` fork chain for a 4-line file.
6. Replace `ka_proc_signature`'s `readlink`/`tr`/`sed` forks with pure-Bash reads;
   it runs for every PID in every session's ancestry on every cycle.

## Resolved on 2026-08-23: stale line tails corrupted redrawn frames

`ka_tui_frame_end` emits `ED 0`, which erases only from the cursor downward. It never
erased the tail of a line that the new frame overwrote with shorter content, so any
change in frame height left the old text visible to the right of the new text.

Reported from live use and reproduced exactly: after `reset main`, and after adding a
message in the wizard, the key-hint footer appeared twice. Rendered screen before the fix:

```text
6:|  a add    e edit    x remove    up/down select    Enter continue    Esc cancel
7:|  a add    e edit    x remove ...    Esc cancel-------------------+
```

Row 6's new content was a bare `|`; the rest of the old hint survived. Row 7 shows the
new hint with the old box bottom's tail still attached.

Every drawn line now ends with `EL 0`. The rewrite was applied only to screen-drawing
`printf` format strings: `ka_tui_sort_index_rows` pipes TSV to `sort`, and `printf -v`
builds strings, so both were excluded. Adding escapes there would corrupt data.

Coverage: unit assertions that each frame primitive erases its own tail, plus a
screen-level pty test that renders the capture through a small VT emulator and asserts
the hint appears exactly once. The byte stream alone cannot show this class of bug.

## Resolved on 2026-08-23: a slow bus no longer stalls IPC or freezes timers

`ka_konsole_discover` now bounds one pass with `KEEPALIVE_DISCOVERY_BUDGET_MS`
(default 1000) and ends with a `#COMPLETE` or `#INCOMPLETE` sentinel.
`ka_state_refresh_discovery` commits only a complete pass, so a truncated one retains
the previous snapshot instead of publishing what looks like sessions disappearing. The
service loop warns once per stale episode. Verified live: a normal pass reports
`#COMPLETE`, and a 1 ms budget degrades to `#INCOMPLETE` rather than blocking.

Original finding follows.

### Original finding: a slow bus stalls IPC and silently freezes timers

The daemon is single threaded. Discovery is 8 qdbus calls with 2 sessions and 60 with
16, each bounded at `KEEPALIVE_QDBUS_TIMEOUT` (default 2 s). A degraded bus therefore
blocks the loop for up to 16 s in the small case and up to 120 s in the observed
16-session case. During that window:

- the FIFO is not read, so clients exceed their 8 s response timeout;
- `elapsed` exceeds `KEEPALIVE_SUSPEND_GAP` (default 2 s), so `ka_scheduler_tick`
  takes the preserve branch and **no countdown advances at all**;
- every non-unavailable target logs a `PRESERVED` line on every such tick.

The failure is silent: keep-alives simply stop firing while the UI still shows them
as `ACTIVE`. Today the margin is comfortable (measured 0.25 s per cycle against a 2 s
threshold) but it narrows linearly with Konsole session count.

Recommended: give discovery a per-cycle wall-clock budget and resume it on the next
iteration, or spread it across iterations one service at a time, so the loop period
stays bounded regardless of bus health.

## Resolved on 2026-08-22: event logs are bounded

`ka_log_event` counts writes per target and trims to `KEEPALIVE_LOG_MAX_LINES`
(default 2000) every `KEEPALIVE_LOG_CHECK_EVERY` events (default 200), so the check
costs one `tail` per 200 events rather than one per event. `ka_scheduler_preserve_gap`
now writes one entry per contiguous gap episode instead of one per target per tick,
via `KA_SCHEDULER_GAP_ACTIVE`.

Original finding follows.

### Original finding: event logs grow without bound

`ka_log_event` appends and nothing ever trims. `ka_log_all` loads the whole file with
`mapfile` into the client, so a large log is a client hang, not just disk use.

The `PRESERVED` path is the amplifier: `ka_scheduler_preserve_gap` writes one line per
non-unavailable target on every tick where elapsed exceeds the suspend gap. Under the
stall above, that is one line per target per loop iteration for as long as the
condition lasts.

Recommended: cap each log (trim to the last N lines on write, or rotate), and
rate-limit repeated `PRESERVED` events to one per contiguous gap.

## Resolved on 2026-08-22: a clean stop is no longer a failure

`keepalive.service` sets `SuccessExitStatus=129 130 143`. Verified on the live host: the
stop at 23:26:50 logged `Stopping` then `Stopped` with no `Failed with result`, where the
22:25:23 stop under the old unit did.

Original finding follows.

### Original finding: a clean stop is recorded as a failure

`lib/service.sh` maps signals to `exit 130/143/129` and the unit sets
`Restart=on-failure` with no `SuccessExitStatus`. systemd therefore logs a normal stop
as a failure:

```text
keepalive.service: Main process exited, code=exited, status=143/n/a
keepalive.service: Failed with result 'exit-code'.
```

Recommended: add `SuccessExitStatus=129 130 143`, or exit 0 from those traps.

## Resolved on 2026-08-23: dead code removed, the security control wired up

`KA_DISCOVERY_DIR` and `KA_STATE_HOME` are gone; neither was ever read.
`ka_runtime_is_xdg` now backs `ka_runtime_secure`, which is what it was written for.

## Enhancement candidates

Not defects; recorded so the next agent does not have to rediscover them.

- **Scriptable surface — done on 2026-08-22.** The CLI now exposes `create`, `delete`,
  `pause`, `resume`, `send [secondary]`, `reset`, and `mode`, plus `list --json`.
  `pause`/`resume` are idempotent and resolve the current state client-side rather than
  growing the IPC protocol. The integration suite drives the full lifecycle through the
  public CLI, which previously required a terminal UI.
- **Machine-readable output — done on 2026-08-22.** `keepalive list --json` emits one
  object per row, escaped through `ka_json_escape`, and the suite validates it with a
  real JSON parser.
- **Atomic submit.** `MESSAGE_ENTER` is two `sendText` calls separated by a sleep, which
  is the documented duplicate-text window. Sending `message + carriage return` in a
  single `sendText` would close it. Unverified: some AI CLIs debounce input, which is
  presumably why the gap exists, so this belongs behind an option and needs live testing.
- **Pluggable delivery.** `ka_konsole_deliver` is the only Konsole-specific write path.
  A transport interface would allow tmux `send-keys`, kitty and WezTerm remote control,
  and GNU Screen, removing the v1 Konsole-only limitation without touching the state
  machine.
- **Signal-driven discovery.** Subscribing to `org.freedesktop.DBus.NameOwnerChanged`
  would let the daemon learn when Konsole services appear or vanish instead of polling
  every 3 s, which is the structural fix behind remedies 1-3 above.
- **Send policy.** Jitter to avoid synchronized sends across targets, retry with backoff
  instead of waiting a whole interval after a transport failure, and optionally skipping
  a send while the AI process is visibly busy.
- **CI — added on 2026-08-23.** `.github/workflows/ci.yml` runs the aggregate developer
  check on every push and pull request. ShellCheck runs as a separate advisory job with
  `continue-on-error`, because the codebase has never been verified against it and no
  ShellCheck is available in the development environment; promote it to required once the
  findings are cleared. `KEEPALIVE_SKIP_SHELLCHECK=1` excludes it from the blocking job.

## Superseded: discovery cost scales with total Konsole sessions, not targets

**This was resolved on 2026-08-22.** See "Resolved on 2026-08-22: daemon CPU reduced
roughly fourfold" above for the fix and its measurements. The original analysis is kept
below because its cost model is still the right way to reason about this area.

Measured on the live workstation with **zero** keep-alives configured: the daemon
consumed 49,369 s of CPU over 86,673 s of wall time, a sustained **57% of one core**
for 24 hours.

`ka_state_refresh_discovery` runs every `KEEPALIVE_DISCOVERY_INTERVAL` (3 s) and
rebuilds everything from scratch. With 11 Konsole services exporting 16 session
objects, one cycle issues `1 + 11 + 3×16 = 60` qdbus calls. Each is a
`timeout` + `qdbus6` pair, and `qdbus6` is a Qt binary that connects to the bus and
exits. On top of that, `ka_proc_signature` costs roughly six forks per PID examined
(`readlink`, `tr`, `sed`, plus command substitutions) across the ancestry walk for
every session. That is on the order of 100 process spawns per second, sustained,
independent of how many targets are actually monitored.

`KEEPALIVE_HEALTH_INTERVAL` (2 s) adds three more qdbus calls per monitored target,
which is the part that correctly scales with real work.

Recommended directions, roughly in order of value:

1. Skip or heavily back off discovery when no target is monitored and no client is
   attached; the daemon only needs fresh discovery to populate `AVAILABLE` rows.
2. Cache service/session paths and re-enumerate them on a much slower cadence than
   the per-session property reads.
3. Batch the three per-session property reads into one call if Konsole exposes a
   suitable interface, or use `org.freedesktop.DBus.Properties.GetAll`.
4. Replace `ka_proc_signature`'s external commands with pure-Bash reads;
   `ka_proc_cmdline` in particular forks `tr` and `sed` per PID.
5. Longer term, the documented native persistent D-Bus/signal design removes the
   polling model entirely.

Any change here must not weaken pre-send identity validation, which is separate
from discovery.

## Resolved on 2026-08-22: TUI overhaul

A full pass over `lib/tui/*` fixed defects that the mocked suite could not reach.
Found by rendering every view at 15 widths x 3 states x 4 presentation modes and by
driving the real client through a pseudo-terminal.

**Any unrecognized escape sequence quit the view.** `ka_tui_read_key` read a fixed
two bytes after `Esc` and mapped anything it did not recognize to `ESC`. From the
manager that exits the client, so Right/Left arrow, function keys, keypad keys, and
xterm's `ESC [ n ~` Home/End all terminated the TUI. This was the user-reported
"pressing any other key exits". The decoder now reads byte by byte, treats only a
bare `Esc` as cancel, and reports unrecognized sequences as `UNKNOWN`, which no view
acts on.

**A key typed right after `Esc` was swallowed.** The follow-up byte was discarded,
so `Esc` plus a fast keystroke lost the keystroke and misread the pair as a
sequence. That byte is now queued in `KA_TUI_PENDING_KEY` and delivered next.
This was reproducibly flaky before the fix and is deterministic after it.

**A failed action exited the client.** Under the entrypoint's `set -e`, a non-zero
return from a wizard cancel or a rejected daemon action escaped the loop body and
terminated the TUI. Cancelling the wizard reproducibly exited with status 1 at
`d75123f`. Navigation and actions are now absorbed by `ka_tui_open_row` and
`ka_tui_guard_action`.

**Frames used fixed-width literals.** Box rules were hard-coded at 78/71/64/63/29/27
dashes regardless of terminal width, so headers wrapped on an 80-column terminal and
fell short on a wide one. All rules are now computed from live width.

**Narrow terminals printed untruncated text.** Derived widths such as `cols - 24`
went non-positive below the minimum width, and `printf '%.*s'` treats a negative
precision as omitted — so the whole string printed and destroyed the layout.
`ka_tui_field_width` floors the budget and `ka_tui_truncate` clamps.

**`--ascii` was not ASCII.** It only changed progress-bar characters; 75 lines of
Unicode box drawing, selection markers, arrows and ellipses were unaffected. A
glyph set now covers the entire frame.

**Control bytes reached the screen.** Message, directory, and process-label text
passed through unfiltered, so an embedded escape sequence could repaint or
reposition the live frame. `ka_tui_truncate` strips control bytes inline.

**Icon mode shifted every column.** Status padding was computed from the bare status
word while the rendered label also carried an icon and a space.
`ka_tui_status_width` reports the rendered cell count.

**Client temp files leaked.** Wizard scratch directories survived Ctrl-C — five were
found on the live workstation, aged 24 h — and `ka_tui_load_index` leaked an
`index-sort.XXXXXX` file per interrupted frame. The scratch path is now published to
the exit trap, stale ones are swept, and the sort streams through a pipeline with no
temp file at all.

Performance, measured on the review workstation with two rows at 100 columns:

| | before | after |
|---|---|---|
| manager frame | 26.1 ms | 15.9 ms |
| idle poll | 26.1 ms (always rendered) | 0.083 ms |
| effective idle cost at 4 Hz | ~10.4% of one core | ~1.6% of one core |

The wins are cached terminal size instead of `tput` forks per query, one
`state.tsv` parse instead of a dozen command substitutions per detail frame, a
`REPLY`-setting timer-color helper instead of a fork per bar, and repainting only on
real change rather than four times a second.

## Remaining TUI gaps

- Truncation still counts characters, not terminal cells, so wide CJK/emoji
  under-count. A full `wcwidth` table in Bash was judged disproportionate.
- The pseudo-terminal harness used for this review lives in the scratch directory,
  not in `tests/`. Interactive coverage in the suite is still unit-level: key
  decoding is tested from byte streams, but no committed test drives a real pty.
- `ka_tui_prompt_line` uses a blocking `read` with no timeout and no cancel key, so
  a user inside a custom-value prompt must press Enter to leave it.
- `q` closes the manager, detail, and log views but not the wizard, where only `Esc`
  cancels. This is what the on-screen hints say, but it is an inconsistency.

## Resolved on 2026-08-23: message replacement commits through a staged swap

`ka_commit_staged_dir` builds the new rotation beside the live one and commits with two
renames, rolling back if the second fails. The commit window is two renames instead of
the whole copy; previously the live directory was removed and repopulated file by file,
so a crash mid-copy left a partially written rotation in place. `ka_cleanup_staged_dirs`
sweeps abandoned staging and rollback directories at daemon start and profile init.

This is not a true transaction, and the notes deliberately do not claim one: POSIX has
no atomic directory swap. An interruption between the two renames leaves the directory
missing, which the checkpoint loader already rejects and quarantines rather than using,
so the failure remains detectable rather than silent.

Original finding follows.

### Original finding: multi-file operations are not transactions

The documentation describes configuration save as a transaction, but atomicity is
per scalar file or per `state.tsv` rename. Create/configure performs multiple
steps:

- mutate in-memory target arrays;
- remove/replace target message directory;
- write target state and secondary message separately;
- remove/replace global profile message directory;
- write profile scalar files separately.

A crash or I/O failure between steps can leave target messages, target checkpoint,
and profile at different generations. Likewise, clients may briefly observe a
message directory while it is being replaced.

Recommended direction: stage complete versioned target/profile directories and
rename/swap them, or introduce a generation/version marker and recovery rules.
At minimum, document “atomic files/snapshots” rather than whole-save transaction
semantics and add interruption/corruption tests.

## Resolved on 2026-08-23: the /tmp fallback is verified before use

`ka_runtime_secure` is now called from `ka_ensure_runtime_dirs` and is fatal in service
mode. It refuses a symlinked runtime base, refuses one that exists but is not a directory
owned by this user, creates it otherwise, forces mode 700, and warns that the fallback
does not share the login session lifecycle. `ka_runtime_is_xdg` existed for this and had
never been wired up.

Original finding follows.

### Original finding: /tmp fallback conflicts with stated lifecycle and service isolation

When `XDG_RUNTIME_DIR` is unset, runtime state falls back to the predictable
`/tmp/keepalive-$UID/keepalive`. This has three differences from the stated model:

1. `/tmp` is not guaranteed to be removed at logout, so runtime records/logs can
   outlive a login.
2. The predictable base path does not explicitly verify ownership/no-symlink
   before use.

The former third item, `PrivateTmp=yes` giving the service a different `/tmp`
namespace from clients and breaking FIFO/request visibility, no longer applies:
that directive was removed on 2026-08-22 for an unrelated and more damaging reason.
Re-adding any mount-namespace directive would reintroduce both problems at once.

Normal systemd user sessions should provide `%t`/`XDG_RUNTIME_DIR`, so this is a
fallback-path issue. Recommended fix: require a valid owned XDG runtime for service
mode, or implement and test a secure shared fallback with an explicit session
marker. `ka_runtime_is_xdg` exists but is not enforced.

## Resolved on 2026-08-23: a partial send no longer duplicates text

`ka_konsole_deliver` returns 3 when the message reached the terminal but the submit did
not. The scheduler records that in `KA_T_PENDING_SUBMIT` and the next attempt submits the
pending line instead of appending the message again, which is the duplicate-text hazard.
Success clears the flag and advances the rotation, because the message was consumed. The
event log records `FAILED · submit owed` so the state is visible.

`KEEPALIVE_ATOMIC_SUBMIT=1` sends text and submit in a single `sendText`, removing the
partial state entirely. It is opt-in because some AI CLIs debounce input and may submit
before rendering the text, which is why the gap exists.

Original finding follows.

### Original finding: message-plus-Enter delivery is not atomic

`MESSAGE_ENTER` uses two qdbus calls separated by a sleep. If the message call
succeeds and the Enter call fails, the event is logged as failed and rotation does
not advance. A later retry can append the same message again to the terminal input
line. Exactly-once semantics are impossible with the current API sequence, but the
failure mode should be explicit.

Potential mitigations: send message and submit sequence in one `sendText` call if
Konsole behavior is validated to be equivalent, or track/log partial delivery and
avoid blind duplicate retries.

## Resolved on 2026-08-23: the installer restarts a running daemon

`scripts/install.sh` restarts `keepalive.service` when it is already active, so an update
no longer leaves new clients talking to a daemon still executing the previous modules.

Original finding follows.

### Original finding: install updates do not restart loaded daemon code

The installer overwrites the installed source and reloads unit definitions, then
enables/starts the socket. If `keepalive.service` is already running, its Bash
process has already sourced the old modules and continues executing them until a
restart. New clients may run new code against an old daemon/protocol.

Recommended fix: after a successful update, restart an active service (while
preserving same-login target checkpoints) or version/negotiate the IPC protocol.
Test upgrade with an active daemon.

## Resolved on 2026-08-23: self-referential `local` declarations

`ka_state_load_target_dir` began with `local dir=$1 file="$dir/state.tsv"`. Bash expands
every assignment word in a single `local` before creating any of them, so `$dir` there
resolved to an *outer* variable, and errored outright under `set -u` when none existed.

It never surfaced because its only caller, `ka_state_load_all_targets`, happens to have a
loop variable named `dir` holding the same path. Dynamic scoping made a latent crash look
like working code. Found when a new test called the function from a scope without one.

Three more instances lived in `tests/testlib.sh`, where the default-message expansions
`${2:-"... $path"}` and `${3:-"expected '$expected' ..."}` would have failed whenever an
assertion was written without an explicit message.

All four are split into separate `local` statements, and
`tests/test_function_comments.sh` now fails the build on the pattern.

## Resolved on 2026-08-23: the secondary prompt is a one-shot nudge

It repeated every `secondary_interval` for the life of the target. It now fires
automatically at most once per arming, tracked by `KA_T_SECONDARY_DONE` and persisted as
an **optional** `secondary_done` checkpoint field so pre-existing records still load.
`CONFIGURE` re-arms it. Manual `SEND_SECONDARY` always delivers and does not consume it.

## Resolved on 2026-08-23: `e` and `E` reach known delivery states

`e` used to toggle the whole target's delivery mode. It now sends a single Enter
immediately and returns the target to `MESSAGE_ENTER`, which is the "submit what is
there, then carry on normally" action the mode toggle was being used for. It never
consumes a queued message and completes a pending submit if one is owed. `E` maps to the
new `SET_MODE` operation and pins `ENTER_ONLY`. Both are explicit sets, so each key
reaches a known state rather than flipping whichever way the target happened to be.

## Resolved on 2026-08-23: remote and non-session clients find the daemon

`KA_RUNTIME_BASE` was `${XDG_RUNTIME_DIR:-/tmp/keepalive-$UID}`, so a client in any context
that never ran `pam_systemd` - `su`, `sudo -u`, cron, non-interactive remote exec - silently
addressed `/tmp/keepalive-$UID` while the daemon listened under `/run/user/$UID`, and
reported the service as unavailable.

`ka_xdg_resolve_runtime_base` now tries `$XDG_RUNTIME_DIR`, then `/run/user/$UID` when it is
a directory this user owns, then the `/tmp` fallback, and records which one it picked in
`KA_RUNTIME_SOURCE`. `ka_runtime_secure` hardens only the fallback, and `doctor` prints the
base together with its source.

Verified with the installed client: `env -u XDG_RUNTIME_DIR keepalive status` reported
`service unavailable` before and `Keep Alive service: online` after.

## Resolved on 2026-08-23: an unread control FIFO no longer hangs clients

`ka_ipc_signal_request` wrote with `> "$KA_CONTROL_FIFO"`. Opening a FIFO write-only blocks
until a reader appears, so a FIFO left behind by a daemon that died - it creates its own
when systemd has not, and `RemoveOnStop` covers only the socket unit's - froze the client
indefinitely with no output. Verified: the real client hung until killed.

The FIFO is now opened read/write, which never blocks, so a dead daemon surfaces as the
ordinary response timeout. Verified: the same scenario now returns in 8 s with
`Timed out waiting for keepalive service`.

## Resolved on 2026-08-23: a transient I/O failure no longer kills the daemon

Periodic work ran unguarded under `set -e`, so one failed write - a full tmpfs, a
permissions change - aborted the daemon, and `Restart=on-failure` retried every 2 s until
`StartLimitBurst=5` in 10 s tripped and the unit stayed dead. Verified by making the runtime
directory unwritable.

`ka_service_try` now runs each periodic task and degrades a failure to a warning carrying
the real status. Discovery is deliberately *not* wrapped: its non-zero return means "the
pass hit its budget", a normal signal handled by the caller. `ka_service_runtime_present`
additionally exits cleanly when the runtime directory disappears, because that means the
session ended rather than something to retry.

## Resolved on 2026-08-23: smaller reliability items

- **Unhelpful diagnostics.** An unreachable daemon produced `service unavailable:` with no
  reason. `ka_ipc_call` now emits the recorded reason, and the FIFO error names the path.
- **Duplicate send across a crash.** The timer reset and checkpoint happened *after*
  delivery, so a crash in between left the countdown at zero and the restarted daemon
  delivered again. The event is now consumed and checkpointed before delivery, which
  matches the existing policy that a failed attempt still consumes its event; a second
  checkpoint afterwards persists the rotation advance or pending-submit state.
- **Lock contention restart loop.** A second instance failing `flock` returned 1, which
  systemd treated as a failure. It now logs and exits 0, because another instance owning
  the runtime state is not an error.
- **Slow sweeps.** Stale request/response cleanup ran hourly and first ran an hour after
  start. It now runs every `KEEPALIVE_CLEANUP_INTERVAL` (default 300 s) and once at startup,
  with the age threshold in `KEEPALIVE_STALE_REQUEST_MINUTES` (default 30).
- **Fixed response budget.** The client's 8 s wait is now `KEEPALIVE_RESPONSE_TIMEOUT_MS`,
  because a loaded machine can legitimately exceed it and a spurious timeout is
  indistinguishable to the operator from an unreachable service.

## Resolved on 2026-08-23: tuning knobs cannot break the daemon

Six sites interpolated an environment value straight into `(( ))`, which fails two
different ways, both reproduced against a real daemon:

```text
KEEPALIVE_SUSPEND_GAP=abc      -> "abc: unbound variable" under set -u, daemon aborts
KEEPALIVE_HEALTH_INTERVAL=2s   -> "value too great for base", the condition is false
                                  forever and health validation silently never runs again
```

The second is the worse one: `set -e` is suppressed inside an `if` condition, so nothing
crashes and nothing is logged. Every knob now goes through `ka_tunable`, which validates,
falls back to the documented default, and warns once per name. The service loop resolves
its cadences once at entry into locals. `KEEPALIVE_SEND_GAP` is a duration rather than an
integer and gets its own pattern check, since it is handed to `sleep`.

Verified: a daemon started with two bad knobs now runs normally and emits exactly one
warning for each.

## Resolved on 2026-08-23: a degenerate control read can no longer become a busy spin

`ka_ipc_service_read` returned non-zero for both the idle timeout and an abnormal read, and
the loop treated them identically. That read is the loop's *only* pacing. Measured: a
genuine timeout returns 142 after 205 ms, while EOF or an unreadable descriptor returns 1
in about 5 ms - 58 iterations in 0.3 s, roughly 190/s against the intended 5/s. Nothing
crashes, so the unit looks perfectly healthy while burning a core.

The read now returns 0 for a line, 1 for the idle timeout, and 2 for anything else. The
loop reopens the FIFO on an abnormal read and gives up after five consecutive failures so
the service manager can restart a working instance.

## Resolved on 2026-08-23: an unreadable clock no longer floods the journal

The monotonic-read failure warned on every iteration, about five times a second for as long
as the condition lasted, while the discovery warning right below it was already rate
limited. It now warns once per episode and resets when the clock recovers.

## Resolved on 2026-08-23: a missing rotation is recoverable

`ka_scheduler_send_main` marked a target sticky `UNAVAILABLE` when its message files were
gone. The Konsole session and AI process are fine in that case; the configuration is not.
An unavailable record cannot be reconfigured, only deleted and rebuilt, so a data problem
made the target unrecoverable. It now consumes the event, logs a `CONFIG` failure naming
the fix, records the reason for the client, and leaves the target usable.

## Resolved on 2026-08-23: classifier config fails loudly

`classifiers.tsv` is hand-edited, and two plausible mistakes failed silently. A file saved
with CRLF endings left a carriage return on the pattern, so `notepad\r` never matched; the
loader now strips it. A pattern that cannot compile was registered and swallowed by the
`2>/dev/null` on the match; the loader now probes each pattern, refuses the entry, and
names the offending line.

## Resolved on 2026-08-23: daemon CPU with monitored targets

Reported as "keepalive uses a lot of processing resources". Measured on the live
workstation with two active targets:

| state | before | after |
|---|---:|---:|
| client attached | 36.4% of one core | **20.7%** |
| unattended | 38.4% of one core | **7.5%** |

**First, a measurement trap.** Seven daemons were running, not one. Six were orphans from
ad-hoc reproduction scripts in the scratchpad that started `./keepalive --service &` with
no cleanup trap - unlike the committed tests, which have one. Killed clients left them
reparented to systemd, polling for nine hours at ~0.8% each. They inflated every earlier
measurement. Always check `ps -eo args | grep '[k]eepalive --service'` before profiling.

Three causes, all fixed:

1. **The idle backoff never engaged once a target existed.** `ka_service_discovery_interval`
   keyed off target count, so creating one keep-alive pinned discovery to the fast cadence
   permanently - even with nothing attached to read the `AVAILABLE` rows it produces. One
   discovery pass costs 472 ms against the live bus, so at 3 s that alone was ~15.7% of a
   core. Presence now decides on its own.

   The coupling this exposes: health validation reuses the discovery snapshot, so backing
   discovery off would silently age that snapshot. `KA_DISCOVERY_STAMP` now records when a
   pass committed, and `ka_state_validate_from_discovery` refuses data older than
   `KEEPALIVE_SNAPSHOT_MAX_AGE` (default 10 s), falling back to a live check - which for a
   handful of targets is far cheaper than keeping discovery itself fast.

2. **Pure string helpers were reached through command substitution.** `ka_single_line`,
   `ka_safe_id`, and `ka_state_target_dir` now set `REPLY`. They ran roughly ten times per
   checkpoint and per index row, once a second per target. `ka_state_save_target` also
   re-ran `mkdir` and `chmod` on every write; both are now done once at creation.

   | | before | after |
   |---|---:|---:|
   | `ka_state_save_target` | 14.75 ms | 5.00 ms |
   | `ka_state_publish_index` | 12.25 ms | 4.25 ms |
   | `ka_scheduler_tick` (2 targets) | 32.50 ms | 11.00 ms |

3. **Every tick rewrote every target's checkpoint.** A countdown decrement now marks the
   target dirty, and `ka_state_flush_dirty` persists it every
   `KEEPALIVE_CHECKPOINT_INTERVAL` (default 30 s) and on clean shutdown. Recovery already
   treats daemon downtime as a preserved gap, so the worst case is a countdown resuming at
   most one flush interval stale.

Tests keep one printing wrapper, `target_dir` in `testlib.sh`, purely so test expressions
stay readable; production has a single idiom.

## Known: the pseudo-terminal suite is not perfectly deterministic

`tests/test_tui_pty.sh` launches real clients against a real daemon, so it inherits real
timing. Measured after hardening: roughly one harness timeout in fifteen full runs, never a
behavioural assertion.

Mitigations in place: the driver synchronises on expected output rather than sleeps and
scans only output produced since the last key; a wait that fails *before any key is sent*
is reported as `START-TIMEOUT` and retried once, because it means the client never drew and
says nothing about the keys; a plain exit `TIMEOUT` is retried once, because bash's
`read -n1` reconfigures the terminal per keystroke and `tcsetattr` can discard input
arriving in that window.

Deliberately not retried: `WAIT-TIMEOUT`, which is what a key wrongly exiting a view looks
like. That keeps the defect these tests exist for detectable.

## Mitigated, format unchanged: positional TSV parsing around empty fields

Every consumer now decodes empty columns correctly: the TUI uses `ka_tui_split_tsv`,
which splits without `read`, and `ka_state_index_row` uses `awk -F '\t'`. The wire format
itself is unchanged, so a *future* consumer written with `read` would hit the same trap.
Kept here as a standing caution rather than an active defect.

Original finding follows.

### Original finding: positional TSV parsing is fragile around empty fields

Bash treats tab as IFS whitespace and collapses adjacent empty delimiters.
`AVAILABLE` index rows intentionally contain an empty mode field. Direct loading
currently yielded:

```text
status:AVAILABLE mode:0 notify:0 last:'' reason:''
```

The published mode was blank; the TUI parsed `0` into mode due to field collapse.
This is harmless today because available rows do not display/use delivery mode,
but it means the nominal 14-column schema is not faithfully decoded and future
fields could shift.

Recommended fix: encode empty fields with explicit sentinel values, use a
non-whitespace delimiter/length-safe format, or implement a parser that preserves
empty TSV columns. Add exact round-trip tests for all statuses and empty values.

## Resolved on 2026-08-23: sanitization and bounds match their comments

`ka_strip_controls` now removes every control character via `[[:cntrl:]]`, not the named
handful it previously stripped despite a comment claiming otherwise. Main rotations are
capped at `KEEPALIVE_MAX_MESSAGES` (default 64) and every message at
`KEEPALIVE_MAX_MESSAGE_LENGTH` (default 2000), applied to the secondary message too.

Still open from the original list: UUIDs are flattened with `ka_safe_id` for paths but
never validated as UUID syntax, and request directories use `mkdir -p` rather than
exclusive creation. Both are bounded by the runtime directory being private to the user.

Original finding follows.

### Original finding: validation/sanitization boundaries are narrower than comments imply

- `ka_strip_controls` removes ESC and several named controls but not every C0/C1
  terminal control byte, despite its broader role comment.
- User message lengths and message counts have no explicit limits.
- UUIDs are flattened with `ka_safe_id` for paths but not validated as UUID syntax;
  distinct unusual IDs can collide after sanitization.
- Request IDs use seconds, PID, and only 10,000 random suffixes; directory creation
  uses `mkdir -p`, not exclusive creation.
- User classifier regexes are intentionally trusted configuration and can be broad
  or computationally awkward.

All runtime directories are private to the user, which reduces cross-user impact.
Still, explicit bounds, UUID validation, collision-safe directory creation, and
complete terminal-control filtering would make the data contracts stronger.

## Lower priority: remaining UI edge cases

The 2026-08-22 overhaul resolved the layout, clearing, glyph, sanitizing, key
decoding, and leak items previously listed here. What remains:

- Unicode cell width is still approximated by character count.
- No committed test drives the manager/detail/wizard/log loops through a real
  pseudo-terminal; see "Remaining TUI gaps" above.
- The wizard's custom-value prompt cannot be cancelled without pressing Enter.

## Semantics that deserve explicit decisions/tests

These are not necessarily defects, but future maintainers should decide and pin
them down:

1. When main and secondary become due together, implementation sends secondary
   and then main in the same tick. Confirm that “secondary preempts” means ordering
   rather than deferring main.
2. Manual send while `PAUSED` is allowed and resets the respective frozen timer.
   Confirm this is desired UX.
3. A transport failure resets the consumed timer while returning IPC failure. This
   policy is now explicit and covered; revisit only if retry cadence should change.
4. A transient validation timeout also resets a consumed send event but retains
   ACTIVE/PAUSED identity; health and recovery merely retry later.
5. `last_seen` updates in memory on successful health checks but is not checkpointed
   each health cycle; index is current, crash checkpoint may be older until recovery.
6. Creating from a discovery row does not revalidate it inside CREATE; the first
   health/pre-send check catches staleness. Consider validating at creation for
   faster feedback.
7. `UNAVAILABLE` records remain so even if the exact original target were to become
   valid again. This appears intentionally sticky and should remain explicit.

## Existing documented limitations

The repository already acknowledges:

- Konsole-only v1 transport;
- subprocess/polling qdbus rather than native persistent D-Bus/signals;
- best-effort classifier coverage;
- imperfect Unicode cell-width handling;
- mocked rather than live KDE/Parrot validation.

## Recommended next regression tests

In priority order:

1. Exact index encode/decode round trip with internal/trailing empty fields.
2. Both timers due simultaneously, including secondary failure/identity loss.
3. Large-positive injected monotonic movement through the full service loop.
4. Crash/failure between target/profile/message update stages.
5. Multiple concurrent CREATE/CONFIGURE/DELETE requests for one UUID.
6. Real systemd socket activation in an isolated user manager.
7. Pseudo-terminal-driven TUI key/resize/cancel cleanup tests, promoted from the
   throwaway harness used on 2026-08-22 into `tests/`.
8. Terminal cell-width handling for wide CJK/emoji in truncation.
