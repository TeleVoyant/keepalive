# Architecture

## Process model

Keep Alive uses one per-user daemon and any number of disposable clients.

- `keepalive --service`: daemon, normally launched by `systemd --user`.
- `keepalive`: alternate-screen TUI client.
- CLI maintenance commands are also clients.

Only the daemon writes authoritative target state. This is the central concurrency rule.

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

A scheduler gap above `KEEPALIVE_SUSPEND_GAP` defaults to preservation rather than subtraction, preventing sleep/resume catch-up bursts.

Secondary events are checked before main when both become due on the same tick.

## Message rotation

Main messages live as literal numbered files:

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

Target state is atomically checkpointed under `$XDG_RUNTIME_DIR`. A daemon restart in the same login reads those records, validates their exact identity, and continues with stored remaining durations.

No durable active binding is restored after full logout/reboot.

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
