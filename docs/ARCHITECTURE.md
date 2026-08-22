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

Secondary events are checked before main when both become due on the same tick.

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
