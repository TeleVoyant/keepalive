# Keep Alive Manager

Keep Alive Manager is a **Konsole-only, KDE/Wayland-friendly per-user keep-alive service and attachable terminal UI** for long-running terminal AI clients.

It evolves the original single-session Bash keep-alive into one persistent manager that can safely control multiple Claude Code, Codex, Kimi, and other recognized AI CLI sessions at the same time. The daemon owns timers and target state. Running `keepalive` from any terminal opens a disposable TUI client; closing that TUI does **not** stop active keep-alives.

Version: **0.1.0**

## Design goals

- Keep the proven Konsole D-Bus `sendText` delivery mechanism; no focus stealing, `xdotool`, `ydotool`, or Wayland input injection.
- One user-scoped service, never a root/system daemon.
- Discover multiple Konsole AI sessions and identify each by Konsole `shellSessionId` UUID.
- Never automatically reattach an old keep-alive to a replacement terminal.
- Preserve countdowns across pause, suspend-like scheduler gaps, and daemon restart in the same login session.
- Keep unavailable targets visible until the user explicitly deletes them.
- Make every keep-alive's event history independent and runtime-only; logs disappear at full logout/reboot.
- Keep one persistent default profile. Saving configuration updates the selected keep-alive and the profile, but **never mutates other active keep-alives**.
- Support Nerd Font UI icons while providing `--no-icons`, `--no-color`, and `--ascii` client modes.
- Keep the implementation maintainable Bash: focused modules, comments describing every function's role, data-only state files, and dependency-free tests.

## Architecture

```text
                         KDE user session
                                │
                          user D-Bus
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
        Konsole session   Konsole session   Konsole session
          Claude Code          Codex              Kimi
              ▲                 ▲                 ▲
              └─────────────────┼─────────────────┘
                                │ sendText / identity checks
                       Keep Alive service
                     (systemd --user + Bash)
                                │
                ┌───────────────┼────────────────┐
                │               │                │
             timers         target state      event logs
                │               │                │
                └───────────────┼────────────────┘
                                │
                   systemd ListenFIFO endpoint
                                ▲
                                │ request IDs only
                  ┌─────────────┴─────────────┐
                  │                           │
           `keepalive` TUI             second TUI client
```

The FIFO carries only short request IDs. Long messages and configuration values are written into private request directories under `$XDG_RUNTIME_DIR`; the service validates them as **data**, never shell code.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full state and IPC model.

## Requirements

Runtime requirements:

- Linux with `/proc` mounted.
- KDE Konsole as the **managed target terminal**.
- Bash 5+.
- a working `qdbus6`, `qdbus-qt6`, `qdbus`, or compatible qdbus binary.
- `systemd --user` for normal service/socket activation.
- `flock` from util-linux.
- GNU `timeout` from coreutils.
- normal core utilities (`grep`, `sed`, `sort`, `tail`, `find`, `readlink`, `cp`, `mv`).
- `notify-send` is optional; keep-alives work without desktop notifications.
- Nerd Font is optional; use `keepalive --no-icons` if glyphs are unavailable or misaligned.

The TUI itself may be launched from another terminal emulator; **only Konsole sessions are discovered/controlled in v1**.

## Installation

Do not use `sudo`.

```bash
./scripts/install.sh
```

The installer creates:

```text
~/.local/share/keepalive-manager/   installed source/tests/docs
~/.local/bin/keepalive              symlink to installed entrypoint
~/.config/systemd/user/
  keepalive.socket
  keepalive.service
```

It then runs:

```bash
systemctl --user daemon-reload
systemctl --user enable --now keepalive.socket
```

`keepalive.socket` is bound to the graphical user session. **Do not enable user lingering** for this project; there is nothing useful to manage after the graphical/Konsole session has ended.

Verify installation:

```bash
keepalive doctor
keepalive status
```

If `~/.local/bin` is not in `PATH`, add it to your shell configuration.

## Normal use

Open the manager from any terminal:

```bash
keepalive
```

The socket activates the per-user daemon automatically when necessary.

Typical manager screen:

```text
╭─ 󰚩 Keep Alive Manager ─────────────────────────────────────── 13:13:08 ─╮
│ 󰒋 service online   6 AI sessions   3 active   1 paused                 │
│                                   1 available   1 unavailable            │
╰──────────────────────────────────────────────────────────────────────────╯

    TYPE       SESSION                    KEEP-ALIVE          MAIN       NUDGE
  ──────────────────────────────────────────────────────────────────────────
 ❯ 1 󰚩 Claude    Avela                     󰐊 ACTIVE       ███████░░░ 18:42 03:42
   2 󰚩 Claude    Risinx                    󰐊 ACTIVE       ████░░░░░░ 11:04 06:04
   3 󰚩 Claude    Scratch                   󰄬 AVAILABLE          —          —
   4 󰚩 Codex     POMS                      󰏤 PAUSED       █████░░░░░ 13:19 04:51
   5 󰚩 Kimi      research                  󰐊 ACTIVE       ██░░░░░░░░ 06:41    —
   6 󰚩 Gemini    experiments               󰅖 UNAVAILABLE        —          —

  ↑/↓ or j/k navigate    1–9 select    Enter open    r refresh    q quit
```

Colors carry consistent meaning:

- **AVAILABLE**: bright green — recognized AI terminal ready to receive a keep-alive.
- **ACTIVE**: bright red — keep-alive is running.
- **PAUSED**: amber/yellow — timers are frozen.
- **UNAVAILABLE**: dim red — original terminal/AI identity is gone; record remains until deleted.

Timer bars are depletion gauges: more bar means more time remains. Urgency progresses from cyan to yellow/amber to red near the deadline. There is intentionally no blinking.

## TUI navigation

Manager:

```text
↑ / ↓          move selection
j / k          move selection
PgUp / PgDn    move a page
Home / End     jump to first/last row
1–9            directly open that dynamically numbered row
Enter          open selected target / configure AVAILABLE target
r              force discovery refresh
q / Esc        close only this TUI client
```

Closing the UI never stops the service or timers.

### Scripting

Every operation the TUI performs is available from the command line, so keep-alives
can be managed without a terminal UI:

```bash
keepalive list --json                  # machine-readable rows
keepalive create <uuid>                # create from the saved profile
keepalive pause <uuid> / resume <uuid> # idempotent
keepalive send <uuid> [secondary]      # deliver immediately
keepalive reset <uuid>                 # reset the main countdown
keepalive mode <uuid>                  # toggle MESSAGE+ENTER / ENTER ONLY
keepalive delete <uuid>
```

Refused operations return the daemon's specific reason rather than a generic
failure, both on the CLI and in the TUI.

Only a bare `Esc` means back/cancel. Arrow, function, keypad, and other escape
sequences the client does not recognize are ignored rather than being treated as
`Esc`, and a key typed immediately after `Esc` is preserved instead of being
swallowed.

### Rendering

The alternate-screen renderer fully clears the visible terminal on first draw,
between manager/detail/wizard/log views, and after resize. Steady redraws within
one view reuse the screen to avoid visible flashing, and a frame is only redrawn
when the published index, the selection, or the clock actually changes — an idle
manager does not repaint continuously.

Every frame is sized from the live terminal, so headers, section rules, columns,
and truncation adapt from the 52-column minimum upward with no wrapped borders.

Where the terminal supports color, the manager and target detail draw their
header as a colored segment bar; with a Nerd Font it uses powerline caps and
wedges. Legacy presentation modes are complete, not degraded stubs:

| Mode | Header | Frame glyphs |
|---|---|---|
| default | powerline segment bar | Unicode box drawing |
| `--no-icons` | colored segments, no wedges | Unicode box drawing |
| `--no-color` / `NO_COLOR=1` | plain boxed header | Unicode box drawing |
| `--ascii` | colored segments, no wedges | 7-bit `+ - \|` frame |

`--ascii` now covers the whole interface — frame, selection markers, ellipsis and
progress bars — not only the progress bars.

Target detail:

```text
n           send main keep-alive now
s           send secondary keep-alive now
r           reset main timer
p           pause/resume target
 e          toggle whole target: MESSAGE + ENTER ↔ ENTER ONLY
c           guided configuration wizard
l           full independent event log
d           delete this keep-alive record (never kills AI/Konsole)
Esc         back to manager
```

Unavailable targets intentionally expose only safe actions such as logs, delete, and back.

Full log viewer:

```text
↑ / ↓, j/k scroll
PgUp/PgDn   page
g            first event
G            last event
Esc          back
```

## Creating a keep-alive

A recognized but unmanaged AI session appears as green **AVAILABLE**. Select it with arrows + Enter or `1`–`9`.

The guided six-step form configures:

1. ordered main message rotation;
2. main interval (25/15/5 minutes or custom);
3. optional secondary prompt and interval;
4. desktop notifications;
5. whole-target delivery mode (`MESSAGE + ENTER` or `ENTER ONLY`);
6. review and explicit save.

The new keep-alive starts ACTIVE with full countdowns.

The daemon accepts main-message rotations only in canonical contiguous form
(`001`, `002`, ... with no gaps or empty slots). Malformed request data is rejected
before target or profile state is changed.

### Single-profile behavior

There is exactly one persistent profile.

When a keep-alive is created or configured:

- the selected target receives the saved settings;
- the global profile is updated to those settings;
- all other already-active keep-alives remain unchanged;
- a future new keep-alive starts from the latest profile values.

This avoids surprising cross-target timer changes while keeping creation convenient.

## Message rotation and Enter-only behavior

Main messages rotate only when a message is actually sent:

```text
Message 1 → Message 2 → Message 3 → Message 1 ...
```

When `e` switches a target to `ENTER ONLY`, timer events send only carriage return (`\r`) and **do not consume the queued main message**. The queue resumes from the same message if `MESSAGE + ENTER` is later restored.

Every Enter-only event is still logged, for example:

```text
13:14:06  MAIN  [ENTER]  SENT
```

If Konsole transport fails, the event is logged/notified as failed and a manual
caller receives an error. The relevant timer is still reset because the scheduled
event was consumed, and a failed main send does not advance message rotation.

## Secondary prompt semantics

Secondary is an independent timer. When it becomes due it preempts the main event check, sends its nudge, resets only the secondary timer, and leaves the main remaining time untouched by delivery duration.

Manual secondary sends follow the same rule.

## Pause, suspend, and restart behavior

Daemon cadence and countdown arithmetic use monotonic uptime seconds from
`/proc/uptime`, not wall-clock time. Changing the system date therefore cannot
accelerate or freeze timers. If an injected/reinitialized monotonic source ever
moves backward, the daemon preserves every countdown and resets all cadence
anchors to the new value.

### Pause

`p` freezes both main and secondary remaining durations exactly. Resume continues from the same values.

### Suspend / long scheduler gap

If the daemon observes a scheduler gap larger than `KEEPALIVE_SUSPEND_GAP` (default 2 seconds), it treats it as a suspend/stall boundary and **does not subtract the gap**. This prevents catch-up bursts after laptop sleep.

Example:

```text
before suspend: main 08:17
resume:         main 08:17
```

The preservation event is recorded in each applicable target's event log.

### Daemon crash/restart

The daemon checkpoints target countdowns under `$XDG_RUNTIME_DIR`. If systemd
restarts it in the same login session, the service first validates the complete
checkpoint structure and then validates the original live identity before
recovering the stored remaining timers. Malformed, inconsistent, or symlinked
records are moved to runtime `quarantine/` with a reason and any matching event
log; they never enter active daemon state.

A D-Bus validation timeout is transient: recovery/health validation is deferred
without making the target sticky UNAVAILABLE. An actual identity mismatch still
follows the normal sticky-unavailable rule.

No wall-clock catch-up is performed while the daemon was absent.

## Target identity and no automatic reattachment

Each target is identified primarily by Konsole's `shellSessionId` UUID. The service additionally remembers:

- D-Bus service/path as the current address;
- terminal process PID;
- AI root PID;
- AI PID `/proc/PID/stat` start-time field to detect PID reuse;
- foreground process ancestry.

Before every input injection, all identity checks must pass.

Each qdbus subprocess has a hard deadline (two seconds by default). A validation
timeout fails that send attempt but retains the target identity for a later health
check; a timed-out delivery is reported and logged like any other transport
failure.

If the AI process exits or the exact session can no longer be validated, the keep-alive becomes sticky **UNAVAILABLE**. It does not disappear.

If a new terminal later starts in the same `Avela` directory, it has a different UUID and appears independently as **AVAILABLE**:

```text
Claude  Avela   UNAVAILABLE   old UUID
Claude  Avela   AVAILABLE     new UUID
```

The manager never reattaches the old record to the new terminal. Delete the old record with `d` and create a fresh keep-alive if desired.

## AI CLI recognition

Recognition is best-effort and process-tree based. The classifier inspects `/proc/PID/comm`, `/proc/PID/exe`, `/proc/PID/cmdline`, and walks parent processes. This allows detection through common Node/Python/wrapper launch paths rather than relying only on the foreground executable name.

Built-in signatures currently attempt to recognize:

- Claude Code
- OpenAI Codex CLI
- Kimi Code CLI
- Gemini CLI
- Qwen Code
- OpenCode
- Aider
- Goose
- GitHub Copilot CLI
- Amp
- Crush
- Cody
- Plandex
- Mentat
- Continue CLI
- Cline CLI
- Roo CLI
- Amazon Q
- Warp Agent
- Cursor Agent
- OpenHands
- SWE-agent
- GPT Engineer
- Factory Droid
- Junie
- Kilo
- Grok CLI/build tools
- T3 Code
- ForgeCode
- Antigravity-style CLI names

No finite built-in registry can guarantee detection of every current/future/wrapped AI client. Extend it without code changes using:

```text
~/.config/keepalive/classifiers.tsv
```

Format:

```text
# Name<TAB>Bash-extended-regex
My Agent	(^|[ /])my-agent([ /]|$)|@company/my-agent
```

Matching is case-insensitive because the process signature is normalized to lowercase; write extension regexes accordingly.

Use conservative, command/path-specific expressions. Overly broad expressions can classify unrelated processes as AI clients.

## Presentation modes

Default Nerd Font UI:

```bash
keepalive
```

Disable only Nerd Font private-use glyphs:

```bash
keepalive --no-icons
```

Disable ANSI colors:

```bash
keepalive --no-color
```

The standard `NO_COLOR` environment convention is also honored:

```bash
NO_COLOR=1 keepalive
```

Maximum compatibility mode (ASCII bars + no Nerd icons):

```bash
keepalive --ascii
```

Test installed Nerd Font glyphs:

```bash
keepalive --icons-test
```

Presentation flags affect only that client. Two attached clients can use different visual modes while controlling the same service state.

## CLI commands

```bash
keepalive                  open TUI
keepalive list             plain-text manager list
keepalive status           ping service
keepalive refresh          force discovery now
keepalive profile          show current persistent profile
keepalive logs UUID        print one target's runtime history
keepalive doctor           dependency/session diagnostics
keepalive --icons-test     Nerd Font visual check
keepalive --version        version
keepalive --help           command reference
```

`keepalive --service` is internal and intended for `keepalive.service`.

## Service administration

Inspect units:

```bash
systemctl --user status keepalive.socket keepalive.service
```

Follow daemon diagnostics:

```bash
journalctl --user -u keepalive.service -f
```

Restart the daemon while preserving same-login runtime state:

```bash
systemctl --user restart keepalive.service
```

Stop daemon but leave on-demand activation available:

```bash
systemctl --user stop keepalive.service
```

The next request to the FIFO can activate it again through `keepalive.socket`.

Do **not** install a root unit in `/etc/systemd/system`, and do not enable lingering for this service.

## Runtime/config layout

Persistent, survives reboot:

```text
${XDG_CONFIG_HOME:-~/.config}/keepalive/
├── profile/
│   ├── main_interval
│   ├── secondary_enabled
│   ├── secondary_interval
│   ├── secondary_message
│   ├── notifications
│   ├── delivery_mode
│   └── messages/
└── classifiers.tsv        optional extension file
```

Runtime-only, removed with the user runtime directory on full logout/reboot:

```text
$XDG_RUNTIME_DIR/keepalive/
├── control.fifo
├── manager.lock
├── index.tsv
├── service.state
├── targets/<UUID>/
│   ├── state.tsv
│   ├── secondary_message
│   └── messages/
├── quarantine/<record>.<suffix>/
│   ├── record
│   ├── quarantine_reason
│   ├── quarantined_at
│   └── events.log             when a matching log existed
├── logs/<UUID>.log
├── requests/
└── responses/
```

Runtime state files are not shell scripts and are never sourced.

## Event logging

Each keep-alive has a separate runtime event log. Events include:

- creation/configuration;
- automatic and manual main sends;
- automatic and manual secondary sends;
- `[ENTER]` sends;
- pause/resume;
- main timer reset;
- delivery-mode changes;
- suspend-like timer preservation;
- daemon same-session recovery;
- target loss/unavailability;
- send failures.

Deleting a keep-alive deletes its runtime event history. Full logout/reboot removes all runtime history automatically.

## Notifications

When enabled for a target, desktop notifications are attempted for:

- successful keep-alive sends;
- send failures;
- target loss/unavailable transition.

`notify-send` failure is deliberately non-fatal.

Both qdbus and `notify-send` are executed synchronously under finite subprocess
deadlines, so a hung desktop helper cannot block the single daemon loop forever.
The operational overrides are:

| Variable | Meaning | Default |
|---|---|---:|
| `KEEPALIVE_QDBUS_TIMEOUT` | Per-qdbus-call deadline in positive integer seconds | `2` |
| `KEEPALIVE_NOTIFY_TIMEOUT` | Per-notification deadline in positive integer seconds | `2` |
| `KEEPALIVE_MONOTONIC_FILE` | Monotonic clock source; primarily for deterministic tests | `/proc/uptime` |

## Security and safety properties

Important safeguards:

1. **No root daemon.** Installer and service reject root operation.
2. **No focus injection.** Only Konsole D-Bus `sendText` is used.
3. **Strict pre-send validation.** UUID + terminal PID + AI PID/start-time + foreground ancestry.
4. **No automatic reattachment.** Replacement sessions remain separate.
5. **Data-only configuration.** User messages are never `eval`'d or `source`d.
6. **Private runtime state.** `umask 077`, `0700` directories, `0600` FIFO/files.
7. **Atomic snapshots.** Clients see complete state, not partially written files.
8. **Single state writer.** Only the daemon mutates authoritative target state.
9. **Kernel manager lock.** `flock` prevents two daemons controlling the same runtime state.
10. **No catch-up bursts.** Long gaps preserve remaining countdowns.

## Development and tests

Run the complete local validation:

```bash
./scripts/dev-check.sh
```

Run just the dependency-free test suite:

```bash
./tests/run.sh
```

The suite currently covers:

- utility/data safety;
- AI classifier signatures;
- persistent profile behavior;
- canonical contiguous main-message validation and mutation-free CREATE/CONFIGURE rejection;
- target creation/state transitions;
- sticky unavailable + different-UUID replacement behavior;
- timer/send semantics;
- main/secondary transport failure propagation and failure logging;
- Enter-only queue preservation;
- secondary/main independence;
- suspend-gap preservation;
- injected monotonic-clock reads and backward-clock preservation;
- same-session daemon recovery;
- strict checkpoint recovery validation, quarantine reasons, log preservation, and symlink rejection;
- multi-request FIFO handling;
- real daemon/client process boundary with mocked qdbus, including create/send/send-failure/timeout/loss/new-UUID behavior;
- mocked Konsole D-Bus discovery/identity validation and bounded timeout behavior;
- bounded optional notification-helper behavior;
- no-icons/ASCII progress primitives, 7-bit frame glyphs, and artifact-free view-transition/resize clearing;
- terminal key decoding, including unrecognized escape sequences that must not act as `Esc`;
- width-exact frame rules and truncation that never overruns a narrow terminal;
- literal control bytes stripped from rendered messages, directories, and process labels;
- enforcement of a `# Role:` maintenance comment for every function.

See [`docs/TESTING.md`](docs/TESTING.md) and the current [`docs/VALIDATION.md`](docs/VALIDATION.md).

## Source layout

```text
keepalive-manager/
├── keepalive                 public entrypoint
├── lib/
│   ├── common.sh             safe utility/data helpers
│   ├── xdg.sh                runtime/config paths
│   ├── icons.sh              centralized Nerd Font glyph map
│   ├── qdbus.sh              qdbus wrapper/discovery
│   ├── classifier.sh         AI process-tree classifier
│   ├── konsole.sh            Konsole discovery/validation/send
│   ├── profile.sh            single persistent profile
│   ├── state.sh              authoritative target/discovery state
│   ├── scheduler.sh          countdown and delivery semantics
│   ├── logging.sh            per-target runtime history
│   ├── notifications.sh      desktop notifications
│   ├── ipc.sh                FIFO/request-directory protocol
│   ├── service.sh            daemon lifecycle/event loop
│   └── tui/
│       ├── screen.sh         terminal primitives/colors/bars/keys
│       ├── wizard.sh         guided create/configure flow
│       └── tui.sh            manager/detail/log screens
├── systemd/
│   ├── keepalive.socket
│   └── keepalive.service
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   ├── dev-check.sh
│   └── package.sh
├── tests/
│   ├── run.sh
│   └── test_*.sh
└── docs/
    ├── ARCHITECTURE.md
    ├── MAINTENANCE.md
    ├── TESTING.md
    └── VALIDATION.md
```

Every Bash function is expected to have an adjacent `# Role:` comment. A test enforces the convention.

## Known limitations / current validation boundary

- v1 manages **Konsole only**.
- qdbus calls are subprocess-based rather than a persistent native D-Bus connection; appropriate for a small number of interactive terminals, but not hundreds of targets.
- Discovery is polling-based (default 3 seconds) rather than native D-Bus signal subscription.
- AI classification is best-effort and extensible, not mathematically exhaustive.
- Simple Bash string-length truncation cannot perfectly model every complex Unicode grapheme/cell-width case. `--no-icons`/`--ascii` provide compatibility paths.
- The included automated tests use a mocked qdbus endpoint because this build environment does not expose your live KDE/Konsole user D-Bus session. **Live Parrot/KDE runtime validation on the target workstation remains the final integration gate.**

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstaller removes the units, installed source tree, and command symlink. It intentionally leaves the persistent profile at `~/.config/keepalive` so preferences are not destroyed accidentally.
