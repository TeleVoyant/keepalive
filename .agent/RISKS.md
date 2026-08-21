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
2. `PrivateTmp=yes` can give the systemd service a different `/tmp` namespace from
   clients, breaking FIFO/request visibility.
3. The predictable base path does not explicitly verify ownership/no-symlink
   before use.

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

## Lower priority: UI edge cases are mostly untested

- The manager rejects widths below 52, but its decorative header is much wider and
  can wrap in the compact-width range.
- Detail/wizard rendering does not consistently enforce minimum width before using
  derived truncation widths.
- Unicode truncation uses Bash character length rather than terminal cell width.
- Persisted/user-entered messages can contain terminal controls not fully removed
  before rendering.
- Wizard temporary directories are not cleaned by an EXIT trap if interrupted;
  hourly IPC cleanup only scans `requests/` and `responses/`.
- Full manager/detail/wizard/log interaction is absent from automated tests.

The documented `--no-icons` and `--ascii` paths mitigate glyph compatibility, not
all of the layout/control cases above.

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
7. Pseudo-terminal-driven TUI key/resize/cancel cleanup tests.
