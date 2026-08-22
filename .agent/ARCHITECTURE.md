# Architecture and Runtime Flows

## Process and ownership model

```text
TUI / CLI client(s)
  1. write private request directory
  2. write "REQUEST <id>" to FIFO
                 │
                 ▼
systemd user socket: %t/keepalive/control.fifo
                 │ activates/feeds
                 ▼
single Bash daemon (`keepalive --service`)
  ├── discovery via qdbus + /proc classifier
  ├── authoritative target arrays/checkpoints
  ├── independent timer scheduler
  ├── exact pre-send identity validation
  ├── Konsole sendText delivery
  └── atomic merged index + response files
                 │
                 ▼
Konsole user-session D-Bus objects
```

The daemon is single-threaded. It interleaves one FIFO read (up to 0.20 seconds),
monotonic timer work, target validation, discovery, index publication, and stale
IPC cleanup. `flock -n` on `manager.lock` prevents two daemon instances from
owning the same runtime state.

Clients read the atomic `index.tsv`, target checkpoint files, and logs. They never
directly change authoritative target fields. The configuration wizard does build a
request from profile/target files client-side; the daemon validates and applies it.

## Daemon startup

`ka_service_main` executes this sequence:

1. Reject effective UID 0.
2. Resolve XDG paths and create private runtime/config directories.
3. Initialize profile defaults for any missing profile files.
4. Require a valid monotonic source and GNU `timeout`.
5. Find qdbus or abort.
6. Initialize classifier registry and empty state arrays.
7. Acquire the non-blocking manager lock.
8. Open the FIFO read/write, creating it if systemd did not.
9. Install cleanup and signal traps.
10. Fully validate runtime target directories, loading valid records and
    quarantining invalid ones.
11. Discover current recognized Konsole sessions.
12. Strictly validate restored non-unavailable targets.
13. Preserve valid target statuses/countdowns and log `SERVICE` recovery; defer
    D-Bus timeouts and mark definite identity failures sticky `UNAVAILABLE`.
14. Publish the merged index and service status.
15. Enter the permanent loop.

The service status checkpoint contains four TSV rows: `state`, `pid`, `version`,
and `updated`. Normal/signaled exit writes `state=stopped`. Target checkpoints are
left in place for same-login recovery.

## Discovery pipeline

`ka_state_refresh_discovery` rebuilds in-memory discovery from scratch:

1. `ka_qdbus_konsole_services` lists bus names matching
   `org.kde.konsole` or `org.kde.konsole-N`.
2. Each service is queried for `/Sessions/N` object paths.
3. Each session is queried for:
   - `shellSessionId` (primary UUID);
   - `processId` (remembered terminal/session process PID);
   - `foregroundProcessId`.
4. The foreground PID and up to 47 ancestors are classified using `/proc`.
5. The recognized AI PID's `/proc/PID/stat` start-time tick is recorded.
6. Display name/directory come from the AI PID's cwd, falling back to foreground
   cwd and then `unknown`.
7. Foreground cmdline/comm becomes a display label.

One discovery row has 11 tab-separated columns:

```text
UUID  AI_TYPE  NAME  CWD  DBUS_SERVICE  SESSION_PATH  TERM_PID
FG_PID  AI_PID  AI_STARTTIME  FG_COMMAND
```

String fields are converted to one line before output. Discovery is ephemeral;
the `discovery/` runtime directory is created but currently not populated.

## D-Bus transport

Read-only session queries go through `dbus-send` when available, and `qdbus` otherwise.
`ka_dbus_use_send` returns false whenever `KEEPALIVE_QDBUS` is set, which pins the qdbus
path for the test mock and for operators who need the original transport. `dbus-send`
replies are parsed by `ka_dbus_send_scalar`, which trims whitespace and strips the type
token that `--print-reply=literal` still emits for non-string values. Service
enumeration uses `org.freedesktop.DBus.ListNames`; session enumeration introspects
`/Sessions` and reads the child node names.

Every bounded call resolves its deadline through `ka_dbus_timeout_resolve`, which sets a
variable rather than being read through a command substitution.

## Validation classification

| Return | Meaning | Sticky? |
|---:|---|---|
| `10` / `11` | A call completed and returned a different UUID or terminal PID | yes |
| `12` / `13` / `15` | Local `/proc` evidence: process gone, PID reused, ancestry lost | yes |
| `14` | Foreground PID unavailable or non-numeric | yes |
| `20` | Bounded call timed out | no, debounced |
| `21` | Call could not be made at all | no, debounced |

Transient results increment `KA_T_STRIKES` and only become sticky `UNAVAILABLE` after
`KEEPALIVE_VALIDATION_STRIKES` consecutive failures. Strikes live in memory only and
reset on any success, so a checkpoint never carries a grudge across a restart.

Periodic health prefers `ka_state_validate_from_discovery`, which re-derives the same
checks from the discovery snapshot and costs no D-Bus call. It returns 1 for "no usable
snapshot", the caller's signal to fall back to a live call. Pre-send validation always
uses the live path.

## Adaptive discovery cadence

Discovery exists to populate `AVAILABLE` rows for clients. `ka_service_discovery_interval`
sets `KA_DISCOVERY_INTERVAL` once a second, fork-free: the fast interval whenever any
target is monitored or `clients.seen` was touched within `KEEPALIVE_CLIENT_PRESENCE_TTL`,
and `KEEPALIVE_IDLE_DISCOVERY_INTERVAL` otherwise. The TUI refreshes `clients.seen` once
a second through a builtin redirect.

## Target identity contract

A monitored target stores both identity and current address:

```text
primary identity:  Konsole shellSessionId UUID
current address:   D-Bus service + /Sessions/N path
safety bindings:   terminal PID
                   recognized AI PID
                   AI PID /proc start-time field
dynamic condition: current foreground PID descends from the AI PID
```

`ka_konsole_validate_target` checks, in order:

| Return | Meaning |
|---:|---|
| `10` | Session UUID differs. |
| `11` | Terminal/session PID differs. |
| `12` | Remembered AI PID no longer exists. |
| `13` | AI PID start-time differs (PID reuse). |
| `14` | Current foreground PID is unavailable/non-numeric. |
| `15` | Foreground PID no longer descends from remembered AI PID. |
| `20` | A bounded Konsole D-Bus validation call timed out. |
| `21` | A Konsole D-Bus call could not be made at all. |

Health validation runs every two seconds by default, and the exact same validation
runs immediately before every send. Definite identity/process failures transition
an `ACTIVE` or `PAUSED` record to sticky `UNAVAILABLE`, save it, log the reason,
and optionally notify. Returns 20 and 21 are deliberately transient and debounced;
see "Validation classification" above. Discovery never reverses a definite
unavailable state.

## In-memory collections

The daemon uses Bash indexed/associative arrays.

Target order:

```text
KA_T_UUIDS[]
```

Per-target maps:

```text
KA_T_TYPE                 KA_T_NAME
KA_T_DIR                  KA_T_SERVICE
KA_T_PATH                 KA_T_TERM_PID
KA_T_AI_PID               KA_T_AI_START
KA_T_STATUS               KA_T_MODE
KA_T_NOTIFY               KA_T_MAIN_INTERVAL
KA_T_MAIN_REMAIN          KA_T_MAIN_INDEX
KA_T_SECONDARY_ENABLED    KA_T_SECONDARY_INTERVAL
KA_T_SECONDARY_REMAIN     KA_T_SECONDARY_MESSAGE
KA_T_LAST_SEEN            KA_T_REASON
```

Discovery order:

```text
KA_D_UUIDS[]
```

Per-discovery maps:

```text
KA_D_TYPE       KA_D_NAME       KA_D_DIR
KA_D_SERVICE    KA_D_PATH       KA_D_TERM_PID
KA_D_FG_PID     KA_D_AI_PID     KA_D_AI_START
KA_D_CMD
```

The TUI loads the merged index into parallel `KA_R_*` indexed arrays and sorts by
AI family rank (Claude, Codex, Kimi, other), lower-cased type, state rank
(`ACTIVE`, `PAUSED`, `UNAVAILABLE`, `AVAILABLE`), and display name.

## Persisted target schema

Each `targets/<safe UUID>/state.tsv` is a key/value TSV file, parsed with an
explicit case statement and never sourced:

```text
uuid
type
name
directory
service
path
term_pid
ai_pid
ai_start
status
mode
notifications
main_interval
main_remaining
main_index
secondary_enabled
secondary_interval
secondary_remaining
last_seen
reason
```

The secondary prompt is a separate literal `secondary_message` file. Main
messages are literal numbered files under `messages/`, and `main_index` is
zero-based.

Load-time validation is fail-closed before array registration. It requires every
known field exactly once; rejects extra columns in known rows; validates non-empty
identity/display fields, service/path shape, positive PID/start-time/interval
values, exact enums/booleans, remaining-time bounds, and `main_index`; binds the
stored UUID to the target-directory basename; and requires non-symlink state,
secondary, message-directory, and canonical contiguous message files. Unknown
field names remain ignorable for forward compatibility.

Any rejected top-level target entry is moved into a uniquely created
`quarantine/<safe basename>.<suffix>/record` wrapper before the daemon loop starts.
The wrapper also receives `quarantine_reason`, `quarantined_at`, and the matching
event log when one exists. The loader never follows target/message symlinks.

`state.tsv`, scalar profile fields, `secondary_message`, service state, and the
merged index use same-directory temporary-file rename. Message-directory and
multi-file profile replacement are separate operations; see `RISKS.md` for the
resulting crash windows.

## Merged client index

`index.tsv` is regenerated atomically at least once a second and after every
request. It first contains every monitored target, then every currently discovered
UUID that has no monitored record.

Its 14 positional columns are:

```text
UUID  TYPE  NAME  DIRECTORY  STATUS
MAIN_REMAIN  MAIN_INTERVAL
SECONDARY_ENABLED  SECONDARY_REMAIN  SECONDARY_INTERVAL
MODE  NOTIFICATIONS  LAST_SEEN  REASON
```

An unmonitored discovery row uses `AVAILABLE`, zero timer fields, blank mode/last
seen/reason, and notifications `0`. This merge is what permits an old
`UNAVAILABLE` UUID and a new same-directory `AVAILABLE` UUID to coexist.

## State transitions

```text
recognized discovery (no target)
             │
             ▼
         AVAILABLE
             │ CREATE
             ▼
           ACTIVE ◄──────┐
             │ pause     │ resume
             ▼           │
           PAUSED ───────┘
             │
             │ any strict identity failure
             ▼
        UNAVAILABLE
             │ DELETE
             ▼
          removed
```

Details:

- `CREATE` requires a currently discovered UUID and daemon-valid configuration.
- `CONFIGURE` works for `ACTIVE`/`PAUSED`, preserves status, replaces settings and
  messages, resets both countdowns, and sets `main_index=0`.
- Pause/resume freezes values exactly; elapsed time is only subtracted from
  `ACTIVE` records.
- Delivery-mode toggle and main reset are rejected for `UNAVAILABLE`.
- Manual sends are allowed while `PAUSED`, subject to identity and feature checks.
- No operation restores `UNAVAILABLE`; delete and recreate against a newly
  discovered UUID is the intended path.

## IPC protocol

The FIFO is deliberately only a wake-up/framing channel. A normal synchronous
request is:

1. Client generates `<epoch>-<pid>-<4 digit random>`.
2. Client creates `requests/<id>/` mode 0700.
3. Client writes `command`, optional `uuid`, and optional `config/` payload files.
4. Client writes one short `REQUEST <id>\n` line to `control.fifo`.
5. Daemon accepts only `REQUEST`, one safe identifier, and no extra token.
6. Daemon reads request fields, dispatches, republishes the index, and creates
   `responses/<id>/`.
7. Daemon writes `message` first and `status` (`OK`/`ERROR`) last.
8. Client polls every 50 ms for `status`, prints `STATUS<TAB>message`, removes the
   response directory, and times out after 8 seconds by default.
9. Daemon removes the consumed request directory.

The daemon opens the FIFO read/write to avoid EOF busy-spinning. If the FIFO is
absent, a client asks `systemctl --user start keepalive.socket`; the service can
also create/open a FIFO directly for tests. Request/response directories older
than one hour are cleaned hourly.

Operations:

| Operation | Effect |
|---|---|
| `PING` | Liveness response only. |
| `REFRESH` | Rediscover, validate monitored targets, publish. |
| `CREATE` | Create `ACTIVE` target from discovery and update profile. |
| `CONFIGURE` | Replace selected target settings/reset timers and update profile. |
| `DELETE` | Remove selected target directory, arrays, and log. |
| `TOGGLE_PAUSE` | `ACTIVE` ↔ `PAUSED`. |
| `TOGGLE_MODE` | `MESSAGE_ENTER` ↔ `ENTER_ONLY`. |
| `RESET_MAIN` | Restore main remaining to configured interval. |
| `SEND_MAIN` | Manual main delivery and main timer reset; transport failure returns `ERROR`. |
| `SEND_SECONDARY` | Manual secondary delivery and secondary timer reset; transport failure returns `ERROR`. |

All product mutations are delegated to state/scheduler functions rather than
implemented in the IPC switch.

## Scheduler

The loop reads integer monotonic uptime seconds from `/proc/uptime` (or the
injectable `KEEPALIVE_MONOTONIC_FILE` used by tests). Wall-clock date corrections
therefore do not affect scheduling. When elapsed time becomes positive:

1. If elapsed is greater than `KEEPALIVE_SUSPEND_GAP` (default 2), do not subtract
   anything; log a `PRESERVED` gap event for every non-unavailable target.
2. For each `ACTIVE` target, subtract elapsed from main (clamped at zero).
3. If secondary is enabled, subtract elapsed from secondary (clamped at zero).
4. If secondary is due, attempt it first and reset only its timer.
5. If the target remains active and main is due, attempt it and reset main.
6. Save the target checkpoint.

If the monotonic reading moves backward, every countdown is preserved, a timer
event is logged, and all loop cadence anchors are reset to the new reading. A
temporarily unreadable source also preserves countdowns rather than substituting
wall time.

When both timers reach zero in one tick, secondary is delivered first and main is
then also eligible in that same tick. “Preempts” means ordering, not suppression of
the main event.

Main delivery selects `messages/<main_index+1 padded to 3 digits>`. Successful
`MESSAGE_ENTER` advances modulo the count of non-empty numbered files. Enter-only
does not advance. Main and secondary timers are reset after a delivery attempt,
including a transport failure. Transport failure is logged/notified, checkpointed,
and returned nonzero to manual IPC callers. A transient validation timeout follows
the same consumed-event timer policy but does not advance rotation or mark the
target unavailable; a definite identity-validation failure does.

All qdbus calls use GNU `timeout`, defaulting to two seconds per subprocess.
Optional notifications use the same bounded pattern and remain best-effort.

## End-to-end create flow

```text
TUI loads AVAILABLE row
  -> copies persistent profile to runtime wizard temp
  -> edits six steps locally
  -> copies config into CREATE request directory
  -> signals FIFO
daemon
  -> confirms UUID exists in current discovery
  -> validates all config scalar/message fields, including contiguous 001..N rotation
  -> creates target arrays as ACTIVE/full timers/index 0
  -> copies numbered messages
  -> saves target checkpoint
  -> updates global profile
  -> logs CREATED
  -> publishes index and responds OK
TUI reloads row as ACTIVE
```

## End-to-end send flow

```text
timer due or SEND_* IPC
  -> check target/feature/status rules
  -> strict Konsole UUID/PID/starttime/ancestry validation under a per-call deadline
     -> timeout: failed event + timer reset; identity retained for retry
     -> definite mismatch: sticky UNAVAILABLE + log + optional notification
  -> select message or [ENTER]
  -> qdbus sendText(message), optional 0.15 s gap, sendText(carriage return)
  -> log SENT or FAILED; optional notification
  -> rotate main only after successful MESSAGE_ENTER
  -> reset the relevant timer
  -> save target and publish index
  -> return IPC ERROR if transport failed
```

The message and carriage return are two D-Bus calls, not one atomic operation.

## Recovery and lifetime

The service never computes catch-up time from checkpoint timestamps. On a daemon
restart in the same login, it first rejects/quarantines malformed records, then
live-validates structurally sound records and resumes their remaining values
unchanged. A D-Bus timeout defers live validation without changing prior status;
a definite identity mismatch becomes sticky UNAVAILABLE. This intentionally
treats daemon downtime like a preserved gap.

Under a normal systemd user session, `$XDG_RUNTIME_DIR` is removed at full logout,
so active bindings and logs disappear. Persistent profile/classifier files remain.
The `/tmp` fallback has different lifecycle and service-namespace caveats described
in `RISKS.md`.

## systemd lifecycle

`keepalive.socket`:

- `ListenFIFO=%t/keepalive/control.fifo`;
- FIFO 0600 and directory 0700;
- `RemoveOnStop=yes`;
- associated with `graphical-session.target`;
- explicitly activates `keepalive.service`.

`keepalive.service`:

- `ExecStart=%h/.local/bin/keepalive --service`;
- `Restart=on-failure`, two-second delay;
- `UMask=0077`;
- namespace-free hardening only: `NoNewPrivileges=yes`, `RestrictSUIDSGID=yes`,
  `RestrictRealtime=yes`, `RestrictNamespaces=yes`, `LockPersonality=yes`,
  `SystemCallArchitectures=native`, `RestrictAddressFamilies=AF_UNIX`;
- user/graphical-session scoped.

Installation enables only the socket. Stopping the daemon leaves on-demand socket
activation available; stopping/disabling the socket ends that entrypoint.

### Mount-namespace constraint on the daemon

The daemon must run in the caller's mount namespace. Discovery resolves
`/proc/PID/cwd` for the session display name/directory and `/proc/PID/exe` for the
classifier signature, on processes it does not own. Both are magic symlinks that the
kernel resolves against the *reader's* mount namespace, so any namespace-creating
directive makes them fail with `ENOENT` while `comm`, `cmdline`, and `stat` continue
to work — a silent, partial failure rather than a crash.

`PrivateTmp`, `PrivateDevices`, `ProtectSystem`, `ProtectHome`, `ProtectProc`,
`ProtectKernelTunables`, `ProtectKernelModules`, and `ProtectKernelLogs` all trigger
this. `PrivateTmp=yes` shipped until 2026-08-22; see `RISKS.md` for the observed
symptom. Seccomp/prctl-based directives are safe and are what the unit uses.

## TUI frame lifecycle

`ka_tui_enter` initializes an empty active-view marker and a pending resize clear.
`ka_tui_frame_begin` derives its identity from the direct renderer in Bash's
`FUNCNAME` stack. First draw, a different renderer, or `WINCH` emits `HOME` plus
`ED 2` before content; a repeat frame emits only `HOME`. `ka_tui_frame_end` retains
`ED 0` to erase unused content below the completed frame. This central rule covers
manager, detail, logs, delete confirmation, and each wizard step without coupling
navigation code to terminal cleanup.

`ka_tui_frame_begin` is also the only place terminal size is refreshed, via one
`stty size` call, because those transitions are exactly when dimensions can change.
`KA_TUI_COLS`/`KA_TUI_LINES` back `ka_tui_cols`/`ka_tui_lines`, which used to fork
`tput` on every query.

## TUI layout model

No frame literal has a fixed width. `ka_tui_box_top`/`ka_tui_box_mid`/
`ka_tui_box_bottom` build on `ka_tui_box_rule`, which computes fill from
`KA_TUI_COLS` minus the measured label and trailer. `ka_tui_hrule` draws an
indented plain rule sized to the remaining width. `ka_tui_field_width` derives a
content budget with a floor, so a narrow terminal can never yield a non-positive
truncation width — the old failure mode, because `printf '%.*s'` treats a negative
precision as omitted and printed the whole untruncated string.

`ka_tui_truncate` strips control bytes inline, clamps non-positive budgets to
nothing, and uses the active ellipsis glyph. Width is counted in characters, not
cells; wide CJK/emoji still under-count. `ka_tui_status_width` reports the rendered
cell count of a status label including its icon, which is what column padding must
use.

## TUI presentation tiers

`ka_tui_palette_init` caches `setaf`/`setab` for colors 0-7 once. `ka_tui_glyphs_init`
selects box, marker, and powerline glyph sets. Powerline wedges follow icon mode
rather than ASCII mode and are written as `\u` escapes.

```text
color + icons        powerline segment bar with caps/wedges
color, no icons      colored segments, no wedges (backgrounds still separate them)
color + --ascii      colored segments, 7-bit frame elsewhere
no color             plain boxed header
```

`ka_tui_bar_add` tracks visible width as it accumulates; `ka_tui_bar_flush` refuses
to print a bar wider than the terminal and returns non-zero so the caller renders
its boxed fallback instead of emitting a wrapped bar.

## TUI repaint policy

`ka_tui_index_changed` slurps `index.tsv` with `read -r -d ''` — no command
substitution, so an unchanged poll costs no fork — and compares it to the copy the
client last parsed. `ka_tui_main` repaints only when that content changed, the
selection or offset moved, a toast is live, a resize is pending, or the displayed
clock second advanced. Key polling stays at 0.25 s. Measured on the review
workstation: an idle poll fell from a full ~26 ms load-and-render to ~0.08 ms.

## TUI key decoding

`ka_tui_read_key` reads byte by byte. A bare `Esc` (nothing within a 0.05 s
inter-byte window) is `ESC`. `[` or `O` introduces a CSI/SS3 sequence, consumed
through its terminating byte and mapped to `UP`/`DOWN`/`LEFT`/`RIGHT`/`HOME`/`END`/
`PGUP`/`PGDN`, or to `UNKNOWN` when unrecognized. `UNKNOWN` matches no view's case
statement and is therefore ignored.

Any other byte following `Esc` means `Esc` was its own keypress, so that byte is
stored in `KA_TUI_PENDING_KEY` and delivered by the next call rather than dropped.

## TUI checkpoint and index reads

`ka_tui_load_target_fields` parses one target `state.tsv` once into `KA_F_*`. The
detail view previously called a per-field accessor a dozen times, each a command
substitution reparsing the whole file. `ka_tui_split_tsv` splits index rows without
`read`, because tab is IFS whitespace and `read` silently merges adjacent empty
columns and shifts every later field. `ka_tui_load_index` streams its sort through
one pipeline instead of a runtime temp file that leaked whenever a client was
interrupted mid-frame.

## Event logging

Each log line is:

```text
HH:MM:SS<TAB>EVENT<TAB>DETAIL<TAB>RESULT
```

Events include `CREATED`, `CONFIG`, `STATE`, `MODE`, `TIMER`, `TARGET`, `SERVICE`,
`MAIN`, and `SECONDARY`. Text is collapsed to one line. Logs are appended by the
daemon and read with `tail`/`cat` by clients. Deleting a target deletes its log.
