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

Konsole targets live on the user's session D-Bus. A root service would create unnecessary identity/session/privilege problems. The units are intentionally installed under `~/.config/systemd/user` and associated with `graphical-session.target`.

No `loginctl enable-linger` is needed or recommended.

## Activation and IPC

`keepalive.socket` uses:

```ini
ListenFIFO=%t/keepalive/control.fifo
```

A client operation is intentionally two-part:

1. Create a private data-only request directory in `$XDG_RUNTIME_DIR/keepalive/requests/`.
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

## Target identity

Primary identity:

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

Discovery cache is ephemeral and periodically rebuilt from current Konsole sessions.

Monitored target records are retained independently. `index.tsv` is a merged snapshot:

- monitored UUIDs: ACTIVE/PAUSED/UNAVAILABLE;
- discovered UUIDs without monitored records: AVAILABLE.

Therefore an old unavailable Avela and a new available Avela can appear simultaneously if their UUIDs differ.

### Cadence and why it follows client presence

Discovery and health serve different purposes, and conflating them is a mistake this
project has already made once.

**Discovery** enumerates every Konsole session and classifies its foreground process. It
is what produces `AVAILABLE` rows, and those rows exist only for a client to display. One
pass costs up to three bounded D-Bus calls per session - measured at 472 ms against a live
bus with a typical session count - so it is by far the most expensive recurring work the
daemon does.

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
`KA_DISCOVERY_STAMP` records when a pass committed, and health refuses a snapshot older
than `KEEPALIVE_SNAPSHOT_MAX_AGE`, falling back to a live check. For a handful of targets
that fallback is far cheaper than keeping discovery itself fast. Pre-send validation is
always live and never consults the snapshot.

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
any target/profile mutation. Transport failure resets the consumed event's timer
but returns failure to manual IPC callers and never advances main rotation.

## Runtime recovery

Target state is atomically checkpointed under `$XDG_RUNTIME_DIR`. On same-login
restart, the daemon accepts a record only after validating all required fields,
enums, booleans, numeric/range constraints, UUID-to-directory binding, Konsole
service/path shape, required files, canonical message rotation, and message index.
Symlinked target entries, message directories/files, and scalar files are rejected.

Rejected records are moved from `targets/` to a uniquely created runtime
`quarantine/` wrapper containing the original record, a precise reason, a
timestamp, and its matching event log when present. Only structurally valid
records proceed to live identity validation and resume with stored durations.

A bounded D-Bus timeout during recovery or periodic health validation is treated
as transient and leaves the prior ACTIVE/PAUSED status intact for retry. Definite
UUID/PID/start-time/ancestry mismatches still become sticky UNAVAILABLE.

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
intervening call deliberately re-sets it.

**Read-only D-Bus queries prefer `dbus-send` over `qdbus`.** `qdbus6` pays Qt
initialization on every invocation, measured at 12.8 ms against `dbus-send`'s 2.4 ms.
`qdbus` remains the fallback and the only path when `KEEPALIVE_QDBUS` is set, which is how
the test mock stays authoritative.

## Bounded external processes

Every qdbus invocation runs under GNU `timeout` with a two-second per-call default.
The same boundary applies to optional `notify-send` calls. A pre-send validation
timeout fails and consumes only that scheduled/manual timer event without changing
target identity or main rotation; a sendText timeout is a normal transport failure.
Notification timeout/failure is always non-fatal.

## Persistent profile

Only the one default profile survives reboot under `$XDG_CONFIG_HOME/keepalive/profile`.

Configuration save transaction:

```text
selected target ← new config
single profile  ← new config
other targets   ← unchanged
```

## Logs

Each monitored UUID owns one runtime event file under `logs/<UUID>.log`.

The daemon is the writer; TUI/CLI are readers.

Deleting a target deletes its log. Full logout/reboot deletes all runtime logs with the user runtime directory.
