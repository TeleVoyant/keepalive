# Configuration Reference

Keep Alive Manager is configured in two independent ways, and it matters which one you
are reaching for.

**Per-keep-alive settings** - messages, intervals, delivery mode, notifications - are
owned by the daemon and edited through the TUI wizard or the CLI. They live in each
target's runtime state and in the persistent profile at `~/.config/keepalive`. Nothing in
this document changes them.

**Environment variables** - everything below - tune the daemon's own behavior: how often
it looks around, how long it waits for external processes, how much it retains. They are
read by whichever process reads them, so a variable set only in your shell affects only
the client you launch from that shell. To change daemon behavior durably, set it in the
service unit (see [Applying to the daemon](#applying-to-the-daemon)).

## Validation and failure behavior

Integer knobs go through one helper, `ka_tunable`. A value that is not a positive integer
is refused, the default is used instead, and a warning is emitted **once per variable**
for the life of the process. A typo therefore degrades to documented behavior rather than
producing a degenerate loop - `KEEPALIVE_HEALTH_INTERVAL=2s` will not spin the daemon.

Two variables are deliberately outside that helper because they are not integers:
`KEEPALIVE_SEND_GAP` is a decimal duration and is range-checked separately, and
`KEEPALIVE_SUBMIT_SEQ` is an arbitrary string.

## Cadence and scheduling

| Variable | Default | Meaning |
|---|---:|---|
| `KEEPALIVE_DISCOVERY_INTERVAL` | `3` | Seconds between full discovery passes **while a client is attached**. Discovery enumerates Konsole sessions and classifies their foreground processes; it is what populates the `AVAILABLE` rows a client displays. |
| `KEEPALIVE_IDLE_DISCOVERY_INTERVAL` | `30` | Seconds between discovery passes when no client has been seen recently. Discovery exists to serve clients, so with nobody watching it backs off. This is the single largest lever on idle CPU. |
| `KEEPALIVE_CLIENT_PRESENCE_TTL` | `20` | Seconds a client is still considered attached after its last request. Governs the switch between the two cadences above. |
| `KEEPALIVE_HEALTH_INTERVAL` | `2` | Seconds between health checks of **monitored** targets. Independent of discovery: a monitored target is validated on this cadence whether or not anyone is watching. |
| `KEEPALIVE_STATUS_INTERVAL` | `15` | Seconds between published status index refreshes. |
| `KEEPALIVE_CHECKPOINT_INTERVAL` | `30` | Seconds between flushes of ticked-down countdowns to disk. A tick marks a target dirty rather than rewriting its checkpoint every second; transitions and deliveries still checkpoint immediately, and a clean shutdown always flushes. Raising this lowers I/O and widens the worst-case staleness after a `kill -9`. |
| `KEEPALIVE_SUSPEND_GAP` | `2` | Seconds of unaccounted elapsed time above which the scheduler treats the gap as a suspend rather than as normal drift, and preserves countdowns instead of burning them down. |
| `KEEPALIVE_CLEANUP_INTERVAL` | `300` | Seconds between sweeps of abandoned request directories and stale runtime files. |

## Timeouts and budgets

| Variable | Default | Meaning |
|---|---:|---|
| `KEEPALIVE_QDBUS_TIMEOUT` | `2` | Seconds any single D-Bus call may take before it is killed. Bounds the blast radius of a wedged Konsole. |
| `KEEPALIVE_DISCOVERY_BUDGET_MS` | `1000` | Milliseconds one whole discovery pass may take. Each session costs up to three bounded D-Bus calls, so without a pass budget a degraded bus blocks the daemon loop, overshoots the suspend gap, and silently stops advancing every countdown. On expiry the pass returns what it has and marks itself incomplete. |
| `KEEPALIVE_RESPONSE_TIMEOUT_MS` | `8000` | Milliseconds a client waits for the daemon to answer before reporting the service unreachable. Raise it on a heavily loaded machine or a slow remote link. |
| `KEEPALIVE_NOTIFY_TIMEOUT` | `2` | Seconds `notify-send` may take. A missing or hung notification daemon must never delay delivery. |
| `KEEPALIVE_SNAPSHOT_MAX_AGE` | `10` | Seconds a discovery snapshot may be reused for health validation. Past this the daemon falls back to a live check, which for a handful of targets is far cheaper than keeping discovery itself fast. Pre-send validation is always live and ignores this. |
| `KEEPALIVE_VALIDATION_STRIKES` | `5` | Consecutive transient validation failures tolerated before a target is given up on and marked `UNAVAILABLE`. Debouncing prevents one D-Bus hiccup from destroying a healthy target. |

## Delivery

| Variable | Default | Meaning |
|---|---:|---|
| `KEEPALIVE_SUBMIT_SEQ` | `\r` | The byte sequence used to submit a line. Change only if your AI CLI needs something other than a carriage return. |
| `KEEPALIVE_SEND_GAP` | `0.15` | Seconds between sending the message text and sending the submit sequence. A decimal duration, not an integer. The gap exists because some AI CLIs debounce input and would otherwise submit before rendering the text. A malformed value warns and falls back. |
| `KEEPALIVE_ATOMIC_SUBMIT` | `0` | Set to `1` to send text and submit in a single `sendText` call. This removes the partial-delivery state entirely, but defeats the debounce protection above, so it is opt-in. |

With the default two-step delivery, a failure between the two steps is recorded as
**owed** rather than retried blindly - a blind retry would append the message twice. The
next attempt completes the pending line instead of repeating it.

## Retention

| Variable | Default | Meaning |
|---|---:|---|
| `KEEPALIVE_LOG_MAX_LINES` | `2000` | Maximum lines retained in one target's event log before it is trimmed. |
| `KEEPALIVE_LOG_CHECK_EVERY` | `200` | Writes between trim checks. Checking every write would fork `tail` per event, so the cost is amortized. |
| `KEEPALIVE_MAX_MESSAGES` | `64` | Maximum messages in one target's rotation. |
| `KEEPALIVE_MAX_MESSAGE_LENGTH` | `2000` | Maximum characters in a single message. |
| `KEEPALIVE_STALE_REQUEST_MINUTES` | `30` | Age at which an abandoned request directory is swept. |

## Paths and external programs

| Variable | Default | Meaning |
|---|---|---|
| `KEEPALIVE_PER_USER_RUNTIME` | `/run/user/$UID` | The per-user runtime directory checked when `XDG_RUNTIME_DIR` is unset. See [Runtime directory resolution](#runtime-directory-resolution). |
| `KEEPALIVE_QDBUS` | autodetected | Path to the `qdbus` binary. Mainly a test seam; the suite points it at a mock. **Setting this also disables the `dbus-send` fast path below**, so every call is routed through the one binary you named - which is what makes the mock authoritative in tests, and what makes this a poor thing to set in production. |
| `KEEPALIVE_DBUS_SEND` | autodetected | Path to `dbus-send`, preferred over `qdbus` for hot-path calls because it starts in roughly 2.4 ms against `qdbus6`'s 12.8 ms of Qt initialization. |
| `KEEPALIVE_NOTIFY_SEND` | `notify-send` | Path to the desktop notification binary. |
| `KEEPALIVE_MONOTONIC_FILE` | `/proc/uptime` | Source of monotonic time. A test seam for driving the clock deterministically. |
| `KEEPALIVE_SKIP_SHELLCHECK` | unset | Set to any non-empty value to skip the ShellCheck stage in `scripts/dev-check.sh`. The stage also self-skips when ShellCheck is not installed. |

## Runtime directory resolution

The daemon and its clients must agree on one runtime directory or they cannot find each
other. Resolution is deliberate and reported by `keepalive doctor` as a named source:

1. **`xdg`** - `XDG_RUNTIME_DIR` is set and the directory exists. The normal desktop case.
2. **`per-user`** - `KEEPALIVE_PER_USER_RUNTIME` (default `/run/user/$UID`) exists, is not
   a symlink, and is owned by you. This covers SSH sessions where `pam_systemd` did not
   export `XDG_RUNTIME_DIR` but the directory is present.
3. **`fallback`** - `/tmp/keepalive-$UID`. Used only when neither of the above applies.
   Because `/tmp` is shared, this path alone is ownership-checked and permission-hardened
   before use.

All runtime state is created under `umask 077`.

## Presentation

These are not Keep Alive Manager variables, but they affect the client:

| Variable | Effect |
|---|---|
| `NO_COLOR` | Any non-empty value disables color, equivalent to `--no-color`. |
| `TERM` | `dumb` or unset degrades to the plainest rendering path. |

The equivalent flags are `--no-icons` (drop Nerd Font glyphs), `--no-color` (drop ANSI
color), and `--ascii` (drop both, plus box-drawing characters). Each is a complete
rendering path rather than a degraded one; see the Presentation modes section of the
[README](../README.md).

## Applying to the daemon

Setting a variable in your shell affects only clients you launch from it. The daemon is
started by systemd and does not inherit your shell environment.

For one experimental run:

```bash
systemctl --user stop keepalive.service
KEEPALIVE_IDLE_DISCOVERY_INTERVAL=60 keepalive --service
```

To make it durable, use a drop-in so the shipped unit stays untouched:

```bash
systemctl --user edit keepalive.service
```

```ini
[Service]
Environment=KEEPALIVE_IDLE_DISCOVERY_INTERVAL=60
Environment=KEEPALIVE_CHECKPOINT_INTERVAL=60
```

```bash
systemctl --user restart keepalive.service
```

Confirm what the running daemon actually has:

```bash
systemctl --user show keepalive.service -p Environment
keepalive doctor
```

## Tuning for lower CPU

The defaults are tuned for a responsive desktop. If the daemon is running on a machine
where idle cost matters more than how quickly a newly opened Konsole tab appears in the
list:

```ini
[Service]
Environment=KEEPALIVE_IDLE_DISCOVERY_INTERVAL=60
Environment=KEEPALIVE_CHECKPOINT_INTERVAL=60
Environment=KEEPALIVE_STATUS_INTERVAL=30
```

Leave `KEEPALIVE_HEALTH_INTERVAL` alone. It guards the correctness of monitored targets -
raising it delays noticing that a terminal has gone away, which is the one thing this
tool must not get wrong.
