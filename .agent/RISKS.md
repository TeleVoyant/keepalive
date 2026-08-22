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

## High priority: discovery cost scales with total Konsole sessions, not targets

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
