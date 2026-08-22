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

## Medium priority: a slow bus stalls IPC and silently freezes timers

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

## Low priority: dead code and an unwired security control

- `KA_DISCOVERY_DIR` is created every startup and never written to.
- `KA_STATE_HOME` is resolved and never used.
- `ka_runtime_is_xdg` is defined and never called. This is the check that was meant to
  gate the predictable `/tmp/keepalive-$UID` fallback; leaving it unwired is why the
  fallback still has no ownership or symlink verification.

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
- **No CI.** There is no `.github/` workflow, so the suite runs only when someone
  remembers to.

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

## Medium priority: multi-file operations are not transactions

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

## Medium priority: `/tmp` fallback conflicts with stated lifecycle and service isolation

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

## Medium priority: message-plus-Enter delivery is not atomic

`MESSAGE_ENTER` uses two qdbus calls separated by a sleep. If the message call
succeeds and the Enter call fails, the event is logged as failed and rotation does
not advance. A later retry can append the same message again to the terminal input
line. Exactly-once semantics are impossible with the current API sequence, but the
failure mode should be explicit.

Potential mitigations: send message and submit sequence in one `sendText` call if
Konsole behavior is validated to be equivalent, or track/log partial delivery and
avoid blind duplicate retries.

## Medium priority: install updates do not restart loaded daemon code

The installer overwrites the installed source and reloads unit definitions, then
enables/starts the socket. If `keepalive.service` is already running, its Bash
process has already sourced the old modules and continues executing them until a
restart. New clients may run new code against an old daemon/protocol.

Recommended fix: after a successful update, restart an active service (while
preserving same-login target checkpoints) or version/negotiate the IPC protocol.
Test upgrade with an active daemon.

## Lower priority: positional TSV parsing is fragile around empty fields

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

## Lower priority: validation/sanitization boundaries are narrower than comments imply

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
