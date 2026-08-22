# Project Context

## Product intent

Keep Alive Manager keeps interactive terminal AI sessions responsive without
stealing focus or injecting desktop input. It sends text directly to a live
Konsole session over the user's D-Bus connection.

The product is intentionally:

- per-user, not root or machine-wide;
- bound to a graphical login session, with no user lingering;
- Konsole-targeted in v1, although the manager TUI can be launched elsewhere;
- multi-target, with independent settings, timers, state, and logs;
- attachable, so closing a client does not stop the daemon or its timers;
- conservative about identity, never guessing that a new tab replaces an old one;
- implemented in dependency-light Bash rather than a native D-Bus application.

## User-visible behavior

The default `keepalive` invocation opens an alternate-screen TUI. It shows every
currently recognized AI session plus retained monitored records in four states:

- `AVAILABLE`: discovered and recognized, with no keep-alive record yet.
- `ACTIVE`: monitored and counting down.
- `PAUSED`: monitored with both timers frozen.
- `UNAVAILABLE`: the original identity failed validation; retained until delete.

An `AVAILABLE` row enters a six-step wizard. Existing records have a detail screen
for manual sends, pause/resume, main-timer reset, delivery-mode toggle,
reconfiguration, logs, and deletion. Deletion removes manager state and that
target's runtime log only; it never kills the AI process or closes Konsole.

The supported public commands are:

```text
keepalive                                  TUI
keepalive list [--json]                    plain session table or machine-readable rows
keepalive create UUID                      create from the saved profile, no wizard
keepalive delete UUID                      remove one keep-alive and its history
keepalive pause UUID | resume UUID         idempotent freeze/resume
keepalive send UUID [secondary]            immediate delivery
keepalive reset UUID                       reset the main countdown
keepalive mode UUID                        toggle delivery mode
keepalive status                           daemon ping
keepalive refresh                          immediate discovery/validation
keepalive profile                          print persistent defaults
keepalive logs UUID                        print one runtime event log
keepalive doctor                           dependency/session diagnostics
keepalive --icons-test                     Nerd Font sample
keepalive --version                        version
keepalive --help                           help
keepalive --no-icons|--no-color|--ascii    client-local presentation modes
keepalive --service                        internal daemon entrypoint
```

## Default profile

There is exactly one persistent default profile. A create or configure operation
applies the submitted values to the selected target and then updates that global
profile. Other already-monitored targets do not change.

Defaults:

| Field | Default |
|---|---|
| Main interval | `1500` seconds (25 minutes) |
| Main messages | one message: `ping` |
| Secondary enabled | `0` |
| Secondary interval | `600` seconds |
| Secondary message | `Continue if there is unfinished work.` |
| Notifications | `0` |
| Delivery mode | `MESSAGE_ENTER` |

Reconfiguring an existing target resets both of that target's countdowns and its
main rotation index. Pausing preserves remaining durations. Manual main sends
reset the main timer; manual secondary sends reset only the secondary timer.

## Delivery rules

- `MESSAGE_ENTER`: send the current main/secondary message, wait 0.15 seconds by
  default, then send carriage return.
- `ENTER_ONLY`: send only carriage return.
- Successful main `MESSAGE_ENTER` delivery advances the main message index modulo
  the count.
- `ENTER_ONLY` never consumes the queued main message.
- Secondary delivery never resets or subtracts the main countdown.
- A target is identity-validated immediately before every manual or automatic
  send.
- D-Bus validation timeouts fail the event but remain transient; they never prove
  identity loss or make the record sticky UNAVAILABLE.
- A transport failure is returned to manual IPC callers after the consumed timer
  is reset; failed main delivery never advances rotation.
- qdbus and notification subprocesses have finite per-call deadlines.
- Notifications are optional and timeout/failure is non-fatal.

## Dependencies and platform assumptions

Runtime requirements:

- Linux with readable `/proc` metadata;
- Bash 5 or newer (`set -Eeuo pipefail` is used throughout entry scripts/tests);
- KDE Konsole for managed targets;
- a working `qdbus6`, `qdbus-qt6`, `qdbus`, Qt 5 fallback, or an executable named
  by `KEEPALIVE_QDBUS`;
- `systemd --user` for supported installation/socket activation;
- `flock`, GNU `timeout`, coreutils/findutils-style utilities, `sed`, `grep`, `sort`, `awk`,
  `readlink`, `tput`, and `stty`;
- optional `notify-send` and optional Nerd Font glyph support.

The test suite itself is plain Bash and has no Bats/Python dependency. ShellCheck
is optional in the aggregate developer check.

## Source map

| Path | Responsibility |
|---|---|
| `keepalive` | Sources all modules, initializes XDG paths, parses CLI roles/options. |
| `lib/common.sh` | Data-safe scalar I/O, atomic single-file writes, IDs, time/duration, sanitization. |
| `lib/xdg.sh` | Persistent/runtime path resolution and private directory creation. |
| `lib/icons.sh` | Central Nerd Font semantic glyph map and icon-free fallback. |
| `lib/qdbus.sh` | qdbus executable selection and deadline-bounded invocation. |
| `lib/classifier.sh` | Built-in/user AI signatures and `/proc` ancestry inspection. |
| `lib/konsole.sh` | Session discovery, exact identity checks, `sendText` delivery. |
| `lib/profile.sh` | One persistent profile, defaults, validation, copying, updates. |
| `lib/logging.sh` | Per-UUID, runtime-only event histories. |
| `lib/notifications.sh` | Optional deadline-bounded `notify-send` wrappers. |
| `lib/state.sh` | Daemon-owned discovery/target arrays, transitions, strict checkpoint loading/quarantine, merged index. |
| `lib/scheduler.sh` | Timer decrement, due-event ordering, validation, delivery, rotation. |
| `lib/ipc.sh` | FIFO signal plus filesystem request/response protocol. |
| `lib/service.sh` | Lock, startup/recovery, daemon loop, health/discovery cadence. |
| `lib/tui/screen.sh` | Terminal lifecycle, cached size, view-aware clearing, key decoding, glyph/palette sets, width-exact frame rules, segment bars, sanitizing truncation. |
| `lib/tui/wizard.sh` | Six-step create/configure request builder plus scratch-directory lifecycle. |
| `lib/tui/tui.sh` | Manager/detail/log rendering, index decoding, single-pass checkpoint reads, change-driven repaint, client action loops. |
| `systemd/*` | User FIFO socket activation and daemon supervision. |
| `scripts/install.sh` | Per-user installed tree, symlink, units, socket enablement. |
| `scripts/uninstall.sh` | Removes installed app/units, intentionally retains profile. |
| `scripts/dev-check.sh` | Syntax, optional ShellCheck, tests, systemd verify. |
| `scripts/package.sh` | ZIP release artifact plus SHA-256. |
| `tests/*` | Dependency-free unit, mock integration, layout, and lint tests. |

All runtime modules are sourced eagerly even for most CLI roles. `ka_xdg_init` is
called at entrypoint load time. Non-early commands then initialize presentation,
runtime directories, and profile defaults before dispatch.

## Persistent and runtime layout

Persistent configuration:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/keepalive/
├── classifiers.tsv
└── profile/
    ├── main_interval
    ├── secondary_enabled
    ├── secondary_interval
    ├── secondary_message
    ├── notifications
    ├── delivery_mode
    └── messages/001, 002, ...
```

Session-scoped state:

```text
${XDG_RUNTIME_DIR:-/tmp/keepalive-$UID}/keepalive/
├── control.fifo
├── manager.lock
├── index.tsv
├── service.state
├── discovery/                  currently unused as on-disk cache
├── targets/<safe UUID>/
│   ├── state.tsv
│   ├── secondary_message
│   └── messages/001, 002, ...
├── quarantine/<safe basename>.<unique suffix>/
│   ├── record
│   ├── quarantine_reason
│   ├── quarantined_at
│   └── events.log                 when present
├── logs/<safe UUID>.log
├── requests/<request ID>/
└── responses/<request ID>/
```

`KA_STATE_HOME` is resolved from `XDG_STATE_HOME` but is not otherwise used.
Target bindings and logs deliberately live in the runtime directory, not the
persistent config directory.

## Supported environment knobs

| Variable | Meaning | Default |
|---|---|---|
| `XDG_CONFIG_HOME` | Persistent config base | `$HOME/.config` |
| `XDG_RUNTIME_DIR` | Login-scoped runtime base | `/tmp/keepalive-$UID` fallback |
| `XDG_STATE_HOME` | Resolved but unused | `$HOME/.local/state` |
| `NO_COLOR` | Disable current client's colors when non-empty | unset |
| `KEEPALIVE_QDBUS` | Explicit qdbus override; also pins the qdbus transport, which is how tests inject their mock | auto-detect |
| `KEEPALIVE_DBUS_SEND` | Explicit dbus-send override | auto-detect |
| `KEEPALIVE_IDLE_DISCOVERY_INTERVAL` | Discovery cadence with nothing monitored and no client watching | `30` |
| `KEEPALIVE_CLIENT_PRESENCE_TTL` | How long a client heartbeat keeps discovery fast | `20` |
| `KEEPALIVE_STATUS_INTERVAL` | service.state write cadence (diagnostics only) | `15` |
| `KEEPALIVE_VALIDATION_STRIKES` | Consecutive transient failures before a target is given up on | `5` |
| `KEEPALIVE_LOG_MAX_LINES` | Retained event-log lines per target | `2000` |
| `KEEPALIVE_LOG_CHECK_EVERY` | Events between log-trim checks | `200` |
| `KEEPALIVE_QDBUS_TIMEOUT` | Per-qdbus-call deadline, positive integer seconds | `2` |
| `KEEPALIVE_NOTIFY_SEND` | Explicit executable notification helper override | `notify-send` |
| `KEEPALIVE_NOTIFY_TIMEOUT` | Per-notification deadline, positive integer seconds | `2` |
| `KEEPALIVE_MONOTONIC_FILE` | Injectable uptime source used by the daemon | `/proc/uptime` |
| `KEEPALIVE_SUBMIT_SEQ` | Text used to submit a prompt | carriage return |
| `KEEPALIVE_SEND_GAP` | Delay between message and submit | `0.15` seconds |
| `KEEPALIVE_SUSPEND_GAP` | Elapsed time above which countdowns are preserved | `2` seconds |
| `KEEPALIVE_HEALTH_INTERVAL` | Target validation cadence | `2` seconds |
| `KEEPALIVE_DISCOVERY_INTERVAL` | Konsole discovery cadence | `3` seconds |

The presentation globals `KA_ICONS_ENABLED`, `KA_COLOR_ENABLED`, and
`KA_ASCII_MODE` are client-local; they are not daemon state.

Submitted main-message directories must contain a non-empty contiguous `001..N`
sequence. Validation occurs before create/configure mutation, and only those
three-digit canonical files are copied into target/profile storage.

## AI classification

Discovery walks from each Konsole foreground PID toward its ancestors (maximum 48
levels), returning the nearest recognized process. The signature combines lower-
cased `/proc/PID/comm`, executable basename, and NUL-separated cmdline converted
to spaces.

Built-ins cover Claude, Codex, Kimi, Gemini, Qwen, OpenCode, Aider, Goose,
GitHub Copilot, Amp, Crush, Cody, Plandex, Mentat, Continue, Cline, Roo, Amazon Q,
Warp Agent, Cursor Agent, OpenHands, SWE-agent, GPT Engineer, Factory Droid,
Junie, Kilo, Grok CLI, T3 Code, ForgeCode, and Antigravity-style names.

User extensions are tab-separated `Name<TAB>Bash-extended-regex` rows in
`classifiers.tsv`. Patterns should be lower-case and boundary-specific. Registry
order is deterministic; a safe-ID key collision replaces the earlier entry's
name/pattern without adding another order slot.

## Design decisions that should be treated as intentional

1. No root service and no `loginctl enable-linger`.
2. Konsole D-Bus `sendText`, not focus/Wayland input injection.
3. UUID is identity; directory/name are display metadata only.
4. Sticky `UNAVAILABLE`, with explicit delete and no automatic replacement bind.
5. A single daemon is authoritative; TUI/CLI clients are disposable readers/requesters.
6. Request payloads are files treated as data; none are sourced or evaluated.
7. Runtime target bindings/logs vanish with a proper XDG login runtime lifecycle.
8. Exactly one persistent default profile, with no retroactive propagation to peers.
9. Long scheduling gaps preserve remaining time instead of catching up.
10. Scheduling cadence uses monotonic uptime; backward readings preserve timers and reset anchors.
11. Malformed runtime checkpoints are quarantined before in-memory registration.
12. qdbus and notification helper calls have finite deadlines.
13. Secondary due checks run before main due checks.
14. Enter-only events do not advance main rotation.
15. Every Bash function has an adjacent `# Role:` maintenance comment.
16. TUI view changes and resizes erase the visible alternate screen; steady same-view refreshes do not.
17. The daemon runs in the caller's mount namespace. Unit hardening is restricted to
    seccomp/prctl directives so `/proc/PID/cwd` and `/proc/PID/exe` stay resolvable.
18. Every TUI frame is sized from the live terminal; there are no fixed-width frame literals.
19. Only a bare `Esc` means back/cancel. Unrecognized escape sequences are consumed and
    ignored, and a byte read past an `Esc` is queued rather than discarded.
20. Presentation degrades in defined steps: powerline segment bar, colored segments without
    wedges, plain boxed header. `--ascii` selects a 7-bit glyph set for the whole frame.
21. The manager repaints only on real change (index content, selection, toast, resize, clock
    second), not on every key-poll cycle.
22. User-facing text is stripped of control bytes before rendering.
23. A failed user action never escapes a TUI loop; under `set -e` that would exit the client.
24. Read-only D-Bus calls prefer `dbus-send`; `qdbus` remains the fallback and is pinned
    whenever `KEEPALIVE_QDBUS` is set.
25. Only a completed call that returned a different value, or a local `/proc` check,
    proves identity loss. Unreachable and timed-out calls are transient and debounced.
26. Daemon-side refusals carry their reason to the client; never replace it with a
    generic string.
27. Periodic health may use the discovery snapshot; pre-send validation may not.
28. Event logs are bounded, and repeated gap events are collapsed per episode.
