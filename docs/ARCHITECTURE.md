# Architecture

## Process model

Keep Alive uses one per-user daemon and any number of disposable clients.

- `keepalive --service`: daemon, normally launched by `systemd --user`.
- `keepalive`: alternate-screen TUI client.
- CLI maintenance commands are also clients.

Only the daemon writes authoritative target state. This is the central concurrency rule.

## Terminal rendering

The client enters the terminal's alternate screen and tracks the active renderer
as a view identity. The first frame, a change between manager/detail/wizard/log
renderers, or a `WINCH` resize emits a home plus full visible-screen erase before
drawing. Repeated frames from the same renderer only return home, and the frame
footer erases unused cells below the new content. This removes differently shaped
previous views without introducing a full-screen flash on every manager refresh.

Terminal dimensions are cached and refreshed only on those same transitions, and
every frame derives its rules, columns, and truncation budgets from that cached
width. There are no fixed-width frame literals.

The manager repaints only when the published index content, the selection, the
toast, the resize flag, or the displayed clock second changes. Key polling stays
at 0.25 s for responsiveness while an idle client performs no rendering work.

Presentation degrades in defined steps rather than breaking: a colored segment
bar with powerline glyphs when icons and color are available, colored segments
without wedges under `--no-icons` or `--ascii`, and a plain boxed header when
color is unavailable. `--ascii` selects a 7-bit glyph set for the entire frame.

Key decoding distinguishes a bare `Esc` from a control sequence. Unrecognized
sequences are consumed through their terminating byte and reported as `UNKNOWN`,
which no view acts on, so function and keypad keys cannot exit a screen. A
non-sequence byte read past an `Esc` is queued for the next read rather than
discarded.

## Why a user service

Konsole targets live on the user's session D-Bus, and Orca terminals belong to the same
user. A root service would create unnecessary identity/session/privilege problems. The
units are installed under the user manager's effective
`${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`.

The socket is the only enabled unit and is wanted by the standard user
`sockets.target`, so activation does not depend on KDE or any graphical session. The
service is static, is `BindsTo`/`PartOf` the socket, and may be activated in desktop,
SSH, or headless systemd user sessions. A service failure leaves the socket available for
reactivation; stopping the socket deliberately stops the service before removing the
FIFO.

No `loginctl enable-linger` is needed for normal login-scoped use, and the installer
never changes lingering policy.

## Activation and IPC

`keepalive.socket` uses:

```ini
ListenFIFO=%t/keepalive/control.fifo
```

A client operation is intentionally two-part:

1. Create a private data-only request directory in `<selected-runtime>/keepalive/requests/`.
2. Write the small line `REQUEST <id>` to `control.fifo`.

The service validates/executes the request and writes a response directory.

Long prompts never pass through the FIFO, avoiding `PIPE_BUF` framing problems and complicated shell escaping.

### Supported request operations

```text
PING
REFRESH
CREATE
CONFIGURE
DELETE
TOGGLE_PAUSE
TOGGLE_MODE
RESET_MAIN
SEND_MAIN
SEND_SECONDARY
```

### IPC result contract

A completed command is answered `OK` when the command itself completed. If the
post-command `index.tsv` publication fails, the daemon keeps the command result, marks
publication stale for a paced retry, and appends a deferred-publication warning to the
successful response; it does not invite a client retry that could duplicate a send.
`REFRESH` also answers `OK`, with a warning naming discovery or target-validation failure,
when either pass fails; each backend keeps its last complete snapshot. A client that
reaches its response timeout removes its request directory so a late daemon cannot execute
the request after the caller has given up.

`status --json` is deliberately outside this IPC path: it reads validated snapshots only,
does not activate the service, and does not stamp `clients.seen`.

## Backend boundary

Terminal-specific behavior is split into adapters:

- `konsole.sh` owns Konsole discovery, D-Bus identity checks, and `sendText` delivery;
- `orca.sh` owns every volatile Orca command, JSON path, schema gate, and error mapping;
- `transport.sh` is the small backend-neutral validation/delivery dispatcher used by the
  scheduler, state health checks, and recovery.

The state machine does not parse Orca JSON or know Orca CLI commands. `orca.sh` publishes
the normalized `terminal-v1` contract: display metadata plus an exact runtime, handle,
PTY, process-incarnation, worktree, host, tab, leaf, and agent binding. This seam is
intentional because Orca's interface is evolving. Compatible changes stay inside the
adapter and its mock; incompatible discovery schemas fail closed without replacing the
previous Orca snapshot.

## Target identity

Konsole primary identity:

```text
Konsole org.kde.konsole.Session.shellSessionId UUID
```

Additional safety bindings:

```text
D-Bus service/path       current address
terminal process PID     Konsole terminal process
AI process PID           original recognized AI root
AI process starttime     /proc PID-reuse guard
foreground ancestry      recipient still belongs to original AI tree
```

All checks are repeated immediately before every send.

Orca manager identity:

```text
orca-<runtimeId>-<incarnationId>
```

The stored binding also includes the runtime-scoped terminal handle, PTY ID, worktree ID,
execution host, tab, leaf, and `agentIdentity`. All must match a live `terminal show`
response immediately before delivery. Schema drift or runtime unreachability is
transient; a completed response showing a different runtime/incarnation/binding is
definitive identity loss. Delivery uses one atomic `terminal send --text ... --enter`
request.

### Position-aware classifier contract

Built-in classifier rules inspect only command-identifying positions: `comm`, the resolved
executable path, `argv[0]`, and the identifying script/module/package position for a known
launcher. Launcher option values, shell `-c` payloads, assignments, editor/pager/grep/git
arguments, and arbitrary non-file option values are not searched. User `classifiers.tsv`
entries remain an explicit legacy escape hatch and match the complete lower-case
`comm exe cmdline` signature.

## State machine

```text
recognized session
       │
       ▼
   AVAILABLE
       │ CREATE
       ▼
     ACTIVE ◄──────────┐
       │ p             │ p
       ▼               │
     PAUSED ───────────┘
       │
       │ identity/process loss
       ▼
  UNAVAILABLE
       │
       │ DELETE
       ▼
    removed
```

UNAVAILABLE is sticky. Discovery never changes it back to ACTIVE and never rebinds it to another UUID.

## Discovery versus monitored records

Discovery snapshots are ephemeral in-memory data and are periodically rebuilt from every
enabled backend; no `discovery/` runtime directory is created. Each backend commits
independently: an incomplete Orca response retains only the prior Orca rows while a
complete Konsole pass can still commit, and vice versa.

Monitored target records are retained independently. `index.tsv` is a merged snapshot:

- monitored UUIDs: ACTIVE/PAUSED/UNAVAILABLE;
- discovered UUIDs without monitored records: AVAILABLE.

Therefore an old unavailable Avela and a new available Avela can appear simultaneously if their UUIDs differ.

### Cadence and why it follows client presence

Discovery and health serve different purposes, and conflating them is a mistake this
project has already made once.

**Discovery** enumerates each enabled backend. Konsole sessions are classified from their
foreground process; Orca rows already carry an agent identity and are accepted only when
connected, writable, non-orphaned, and structurally complete. Discovery produces
`AVAILABLE` rows, and those rows exist only for a client to display. A Konsole pass costs
up to three bounded D-Bus calls per session - measured at 472 ms against a live bus with a
typical session count - so it remains the most expensive recurring work on that backend.

**Health** validates the identity of already-monitored targets. It is what protects
delivery, so it runs on its own cadence regardless of whether anyone is watching.

Discovery therefore backs off on **client presence alone**, never on target count. A
client counts as attached for `KEEPALIVE_CLIENT_PRESENCE_TTL` after its last request;
after that, discovery drops from `KEEPALIVE_DISCOVERY_INTERVAL` to
`KEEPALIVE_IDLE_DISCOVERY_INTERVAL`. Keying this off target count instead pinned discovery
to the fast cadence forever the moment a single keep-alive existed, which cost roughly
15.7% of a core indefinitely with nobody there to see the result.

Backing discovery off exposes a coupling: health reuses the discovery snapshot to avoid
duplicating work, so a slower discovery would silently age the data health depends on.
Per-backend discovery stamps record when each pass committed. Health refuses a Konsole
snapshot older than `KEEPALIVE_SNAPSHOT_MAX_AGE` or an Orca snapshot older than
`KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE`, falling back to a live adapter check. For a handful of
targets that fallback is far cheaper than keeping discovery itself fast. Pre-send
validation is always live and never consults the snapshot.

That coupling also decides which backends an unattended pass refreshes at all. With no
client watching, the only consumer of a snapshot is health, and health only uses one that
is younger than its maximum age. A backend is therefore refreshed unattended only when it
has a monitored target and its maximum snapshot age reaches the idle interval: by default
Orca (35 s against 30 s), where the snapshot replaces a live CLI call per target, and not
Konsole (10 s), whose idle pass used to scan the whole bus for a result nothing read. A
client's `REFRESH`, and every CLI command, still runs a complete pass first.

Repeated Orca failures - a closed Orca app, or a schema the adapter does not yet accept -
back periodic Orca discovery off exponentially to at most a minute, because every attempt
starts the Electron-based CLI. The previous snapshot is kept throughout, and any
successful pass, including a client's `REFRESH`, ends the backoff.

A pass is also bounded by `KEEPALIVE_DISCOVERY_BUDGET_MS`. Without it, a degraded bus
blocks the daemon loop, which then overshoots the suspend gap and silently stops
advancing every countdown. On expiry the pass returns what it has and reports itself
incomplete.

## Timers

Each monitored target stores integer seconds:

```text
main_interval
main_remaining
secondary_interval
secondary_remaining
```

Only ACTIVE targets decrement.

Cadence uses integer monotonic uptime from `/proc/uptime`; wall-clock corrections
do not affect countdowns. A scheduler gap above `KEEPALIVE_SUSPEND_GAP` defaults
to preservation rather than subtraction, preventing sleep/resume catch-up bursts.
An unexpected backward monotonic reading also preserves all countdowns and resets
timer, health, discovery, publication, and cleanup anchors.

Secondary events are checked before main when both become due on the same tick. The
secondary prompt is one-shot: it fires once and then records `secondary_done` rather than
repeating until reconfigured.

### Loop pacing

The daemon does not poll. Each iteration computes the earliest due periodic task - tick,
health, discovery, index publication, status, flush, cleanup - and blocks in the control
FIFO read until then, capped at five seconds. A client request still wakes the read at
once, so IPC latency is unchanged. Anchors are whole monotonic seconds and the deadline
is computed in milliseconds from the same `/proc/uptime` source.

The one-second tick is planned only while some target is ACTIVE. The tick's elapsed time
is also how a suspend is detected, so while it runs it must run every second; with no
countdown running there is nothing to subtract, and the next tick after a planned long
sleep starts counting afresh instead of reporting a gap. Index publication follows client
presence: every second while a client watches, and every `KEEPALIVE_STATUS_INTERVAL`
otherwise, because every request republishes the index before answering and CLI commands
refresh first. An identical index is not rewritten at all; clients compare content, never
mtime.

An idle daemon with nothing monitored and no client attached therefore wakes once every
five seconds instead of five times a second.

### Stopping and updating

TERM, INT, and HUP are recorded, not acted on mid-work. While the loop waits in the control
read, the trap exits at once - Bash would otherwise resume the read for its whole timeout -
and anywhere else the loop exits at the top of its next iteration. A delivery in flight
therefore completes before the process ends. The pending-submit owner is also persisted
for crash recovery; only an uncatchable kill can leave the provider-side text/Enter outcome
unknown. The unit's `KillMode=mixed` signals only the daemon, so the
helper carrying that delivery is not killed either. The EXIT trap then flushes every dirty
countdown and writes `state stopped`.

That is what lets an update keep running keep-alives: the installer restarts an active
daemon after swapping the code, and the new instance recovers every target from its
checkpoint as it would after any restart. The installer records each target's state
beforehand, waits for the new daemon to report itself online - recovery publishes the
index before that - and reports any target that did not come back. A running manager TUI
holds a descriptor on the entrypoint it was loaded from; when the command it was started as
resolves to a different file and a new daemon is online, it re-executes that command with
its original options and restores the selected row.

### Checkpoint durability

A countdown decrement does not rewrite the target's checkpoint. It marks the target dirty,
and `ka_state_flush_dirty` persists every dirty target on the
`KEEPALIVE_CHECKPOINT_INTERVAL` cadence and on clean shutdown. State transitions and
deliveries still checkpoint immediately, because those are the events that must not be
lost.

The trade is bounded and deliberate. Recovery already treats daemon downtime as a
preserved gap rather than burning it down, so the worst case after an ungraceful kill is a
countdown resuming at most one flush interval stale - it appears to gain a few seconds. A
clean restart loses only the restart gap itself. Writing every countdown for every target
once a second bought nothing against that, and cost a full checkpoint rewrite per target
per second.

## Message rotation

Main messages live as literal, non-symlink numbered files:

```text
targets/<UUID>/messages/001
targets/<UUID>/messages/002
...
```

`main_index` is zero-based. MESSAGE+ENTER success advances it modulo message count. ENTER_ONLY does not advance because no queued message was consumed.

Configuration validation requires a non-empty contiguous `001..N` sequence before
any target/profile mutation. Per-target intervals are integer seconds bounded to
`1..999999999`; scalar reads count UTF-8 code points rather than locale-dependent bytes.
Transport failure resets the consumed event's timer but returns failure to manual IPC
callers and never advances main rotation.

### Pending-submit ownership

A partial text-plus-Enter delivery persists `pending_submit` as one of `0`, `MAIN`,
`SECONDARY_AUTO`, `SECONDARY_MANUAL`, or `STALE`. `0` means no owed Enter; the other
values identify the event that owns the next submit. A persisted legacy value `1` is
loaded as `MAIN`, and an absent field loads as `0`. The owner is completed before a
different event can append text: MAIN completion advances the rotation, automatic
secondary completion consumes `secondary_done`, and STALE completion never advances the
replacement rotation. The one-shot `e` Enter completes an owed owner when present; with
no owner it sends only Enter and leaves the queued message untouched.

CONFIGURE marks any owed owner `STALE`, resets the replacement index to zero, and commits
that checkpoint before swapping the new `messages/` directory. If the daemon stops between
those commits, restart sees a valid replacement state and the STALE Enter cannot advance
its new rotation; this ordering prevents the old owner/index from being paired with new
message files. Rollback restores the prior owner with the prior rotation.

## Persisted service and index contracts

`service.state` is a six-row key/value snapshot:

```text
state
pid
version
updated
updated_epoch
pid_start
```

`pid_start` pairs the published PID with its `/proc` start-time generation so
`status --json` can report a reused PID as offline. The status reader is read-only and
presence-free: it does not contact the daemon, create runtime/configuration state, or
write `clients.seen`.

The merged `index.tsv` has 21 positional columns. Columns 1-15 are the original stable
layout; columns 16-21 are appended compatibility extensions:

```text
1 uuid                 2 type                 3 name
4 directory            5 status               6 main_remaining
7 main_interval        8 secondary_enabled   9 secondary_remaining
10 secondary_interval  11 mode               12 notifications
13 last_seen           14 reason              15 backend
16 next_main           17 next_secondary     18 last_delivery_time
19 last_delivery_event 20 last_delivery_result 21 last_delivery_detail
```

Older readers can continue to consume columns 1-15, while newer readers treat absent
16-21 fields as empty. The `ENTER` event is part of the event vocabulary alongside
`MAIN` and `SECONDARY`: it records the one-shot Enter command and automatic
`ENTER_ONLY` main deliveries, whose detail is `[ENTER]`.

## Runtime recovery

Target state is atomically checkpointed under the selected runtime directory. On same-login
restart, the daemon accepts a record only after validating all required fields,
enums, booleans, numeric/range constraints, target-to-directory binding, the selected
backend's normalized identity binding, required files, canonical message rotation, and
message index.
Symlinked target entries, message directories/files, and scalar files are rejected.

Rejected records are moved from `targets/` to a uniquely created runtime
`quarantine/` wrapper containing the original record, a precise reason, a
timestamp, and its matching event log when present. Only structurally valid
records proceed to live identity validation and resume with stored durations.

A bounded backend timeout during recovery or periodic health validation is treated
as transient and leaves the prior ACTIVE/PAUSED status intact for retry. Definite
identity mismatches still become sticky UNAVAILABLE.

No durable active binding is restored after full logout/reboot.

## Cost conventions in the daemon loop

Two idioms in the source exist for measured reasons rather than taste, and both look
unusual out of context.

**Pure string helpers return through `REPLY`.** `ka_single_line`, `ka_safe_id`,
`ka_state_target_dir`, `ka_now_monotonic`, `ka_now_ms`, and `ka_tunable` set the shared
`REPLY` variable instead of printing. Each call through `$(...)` forks a subshell at
roughly 0.5-1 ms, and these run about ten times per checkpoint and per index row, once a
second per target. Converting them cut `ka_state_save_target` from 14.75 ms to 5.00 ms,
`ka_state_publish_index` from 12.25 ms to 4.25 ms, and a two-target scheduler tick from
32.50 ms to 11.00 ms.

The cost of the idiom is that `REPLY` is a single shared register: it must be read on the
line immediately after the call. Where a function legitimately reads it twice, an
intervening call deliberately re-sets it. Helpers that have both forms are named in pairs:
`ka_proc_starttime` prints for tests and one-off callers, `ka_proc_starttime_set` sets
`REPLY` for loops. The `/proc` classifier, the TUI frame, and the health pass use only the
`_set` forms; the classifier still resolves `/proc/PID/exe` with `readlink`, but caches the
result per PID and start time, re-validated against comm and cmdline.

**Atomic writes start one process.** `ka_atomic_temp` creates the temporary file with a
noclobber (O_EXCL) redirect under a 64-bit random name and relies on the `umask 077` that
`ka_xdg_init` records, so the rename is the only external command per write; `mktemp` and
`chmod` used to add two more. An unchanged secondary-message companion is reused rather
than rewritten on every checkpoint.

**Read-only D-Bus queries prefer `dbus-send` over `qdbus`.** `qdbus6` pays Qt
initialization on every invocation, measured at 12.8 ms against `dbus-send`'s 2.4 ms.
`qdbus` remains the fallback and the only path when `KEEPALIVE_QDBUS` is set, which is how
the test mock stays authoritative.

## Bounded external processes

Every qdbus invocation runs under GNU `timeout` with a two-second per-call default;
every Orca CLI invocation has a three-second default. The same boundary applies to
optional `notify-send` calls. A pre-send validation
timeout fails and consumes only that scheduled/manual timer event without changing
target identity or main rotation; a sendText timeout is a normal transport failure.
Notification timeout/failure is always non-fatal.

## Persistent profile

Only the one default profile survives reboot under
`${XDG_CONFIG_HOME:-$HOME/.config}/keepalive/profile`.

Configuration semantics:

```text
selected target ← new config
single profile  ← new config
other targets   ← unchanged
```

The persistent profile directory is staged completely and swapped as one directory. A sole
rollback directory left by a crash between its two renames is recovered before defaults are
created, and `mv -T` prevents a concurrent directory from turning the stage into a nested
child. Target checkpoints atomically reference a versioned secondary-message payload, and a
reported CONFIGURE failure compensates back to the exact prior target settings. Target main
messages, the target checkpoint, and the profile remain separate commit points; a process
crash between them is detectable/recoverable but not one cross-directory atomic transaction.

## Logs

Each monitored UUID owns one runtime event file under `logs/<UUID>.log`.

The daemon is the writer; TUI/CLI are readers.

Deleting a target deletes its log. Full logout/reboot deletes runtime logs when the
selected base is the normal session-managed user runtime; the hardened `/tmp` fallback
does not claim that lifecycle.
