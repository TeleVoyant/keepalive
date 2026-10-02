# Architecture and Runtime Flows

## 2026-10-01 performance and update-reload invariants

These supersede the older cadence notes below wherever they disagree.

- **Loop pacing.** `ka_service_loop` blocks in the FIFO read until the earliest due task
  (deadline computed from `ka_now_monotonic_ms`, +5 ms, clamped to 1..5000 ms). The
  one-second tick is planned only while some target is ACTIVE, and `ticking` is captured
  before the wait: with no ACTIVE target the next wake resets `last_tick` instead of
  ticking, so a planned long sleep is never mistaken for a suspend gap. Do not make the
  tick slower than 1 s while ACTIVE - its elapsed time is the suspend detector.
- **Presence-driven cadence.** `ka_service_discovery_interval` (every wake) sets
  `KA_CLIENT_PRESENT`, `KA_DISCOVERY_INTERVAL`, and `KA_PUBLISH_INTERVAL` (1 s attended,
  `KEEPALIVE_STATUS_INTERVAL` unattended). `clients.seen` must hold bare epoch digits; the
  parser accepts at most 12 leading digits (1.0.0 TUIs appended `\033[K`, which used to
  disable presence entirely). The TUI stamps presence *before* its first PING.
- **Unattended discovery** runs only for enabled backends with a non-UNAVAILABLE target
  whose snapshot max age >= the idle interval (`ka_service_scan_targets` ->
  `KA_SVC_IDLE_DISCOVERY`); by default Orca yes (35 >= 30), Konsole no (10 < 30). Health
  cadence is unchanged and deliberately not presence-dependent (docs forbid slowing it).
- **Orca backoff**: periodic Orca discovery skips while `KA_ORCA_DISCOVERY_FAILURE` is set
  and `now < KA_ORCA_RETRY_AT` (2,4,..,60 s); any success, a client REFRESH included,
  resets it. REFRESH itself never honours the backoff.
- **Graceful stop.** TERM/INT/HUP call `ka_service_request_stop`: exit at once while
  `KA_SERVICE_WAITING=1` (idle in the read - Bash otherwise resumes `read -t` for its whole
  timeout), else record `KA_SERVICE_STOP` and exit at the top of the next iteration. The
  unit uses `KillMode=mixed`; `KEEPALIVE_SEND_GAP` is capped at 10 s so a stop always fits
  the stop timeout. Never restore `trap 'exit 143' TERM`.
- **Atomic writes** hold the O_EXCL descriptor (`KA_ATOMIC_TMP`/`KA_ATOMIC_FD`), write
  through it, and `ka_atomic_close` re-checks `[[ $tmp -ef /dev/fd/$fd ]]` before the
  rename. Existing temp names (FIFOs included) are skipped before opening. Use `/dev/fd`,
  not `/proc/$$/fd`: `$$` is the parent PID inside a subshell.
- **Index publication** skips the write when the published file is an owned, readable
  regular file whose bytes equal the payload (no in-memory cache - a tampered file is
  always repaired). Clients compare content, never mtime.
- **Konsole discovery** is `ka_konsole_discover_rows` filling `KA_DISCOVERY_ROWS` in the
  caller's shell; `ka_konsole_discover` is only a printing wrapper. Running it behind a
  process substitution would discard the classifier's exe cache every pass.
- **Exe cache** (`KA_PROC_EXE_FP`/`KA_PROC_EXE_PATH`, key `pid:starttime`) needs the
  comm/cmdline fingerprint *and* `[[ /proc/PID/exe -ef cached_path ]]` to hit; bound 1024.
- **REPLY pairs.** Hot helpers have `_set` forms; printing wrappers remain for tests and
  one-off callers. `ka_process_is_descendant_of` and the `ka_proc_*_set` helpers clobber
  REPLY; no caller holds REPLY across them today.
- **Update reload.** `scripts/install.sh` records `uuid<TAB>status` per owned checkpoint
  (`UNREADABLE` when it cannot read one), restarts an active daemon, waits up to 60 s for
  a *different* pid that is owned and holds `manager.lock` open (never trust the pid in
  `service.state` alone), then compares against `index.tsv`. All post-swap reporting is
  best-effort and must never fail an installation whose new tree is live. A TUI holds an
  fd on its entrypoint (`ka_tui_watch_install`); when `KA_INVOKED_AS` (made absolute) no
  longer `-ef` that fd and a new daemon pid is online, it preflights `--version`, restores
  the terminal, and re-execs with `KA_CLI_ARGS`, restoring the row via
  `KEEPALIVE_TUI_SELECT`.

## 2026-10-01 storage and lifecycle invariants

- Every runtime target, request, response, messages directory, state file, and message
  payload is checked as an owned, real path before use. CREATE uses one-level exclusive
  directory creation and never follows a pre-planted target symlink.
- Atomic scalar writers use same-directory `mktemp` files. Target checkpoints first commit
  a versioned `secondary_message.<pid>.<random>` companion, then atomically publish its name
  in `state.tsv`; client configuration seeding reads that file and does not depend on
  daemon-only associative arrays.
- Message-directory commits retain an unrecoverable rollback tree. Service startup recovers
  `messages.trash.*` before loading/quarantining targets and only then sweeps stale stages.
- `manager.lock` is created with noclobber semantics, reopened without truncation, and
  verified through `/proc/$$/fd` before `flock`.
- A completed successful command remains `OK` if its later index publication fails; the
  response carries a deferred-publication warning and the service retries at a paced rate,
  avoiding a client retry that could duplicate a send.
- Install refuses an unrecognized pre-existing application tree. Uninstall snapshots all
  current and legacy enablement links before `disable --now`, restores their exact literal
  targets if shutdown probes abort, always attempts `daemon-reload` after cleanup, and
  returns nonzero for cleanup or reload failure.

## 2026-09-25 Orca backend addendum

The older sections below describe the original Konsole path and remain useful, but the
current daemon is multi-backend. Provider-specific behavior is now deliberately layered:

```text
konsole.sh ─┐
            ├─ transport.sh ─ scheduler / recovery / periodic health
orca.sh ────┘
```

`lib/orca.sh` is the volatility boundary for Orca. It alone owns CLI discovery
(`terminal list`), live identity lookup (`terminal show`), delivery (`terminal send`),
JSON paths, schema validation, and Orca error codes. It publishes the normalized
`terminal-v1` contract. A future Orca release should be adapted there and in
`tests/fixtures/orca-mock`; generic scheduler logic must not parse provider JSON.

An Orca target ID is `orca-<runtimeId>-<incarnationId>`. The full persisted binding is:

```text
backend=orca
orca_handle
orca_pty
orca_incarnation
orca_worktree
orca_runtime
orca_host
orca_tab
orca_leaf
orca_agent
```

Every field is opaque and bounded rather than constrained to today's UUID/prefix format.
Before every send, `terminal show` must reproduce the complete binding and report the
terminal connected, writable, and non-orphaned. A runtime/incarnation/binding mismatch is
definitive; timeout, unreachability, or an unfamiliar response schema is transient.
Delivery is one atomic CLI request containing text plus Enter (or Enter only).

Discovery snapshots are committed per backend. `ka_state_refresh_konsole_discovery` and
`ka_state_refresh_orca_discovery` replace only their own rows after a `#COMPLETE` marker;
the generic refresh collects stale backend names. This prevents an Orca 0.x schema change
from erasing Konsole availability, and preserves prior Orca rows while the adapter is
being updated. Pre-send validation is still live and never trusts that cache.

Checkpoint compatibility is asymmetric by design: no `backend` field means `konsole`, so
all 1.0.0 runtime checkpoints remain loadable. An explicit unknown backend or a malformed
Orca binding is rejected/quarantined. `index.tsv` appends backend as column 15 so older
column positions remain stable; the client defaults a missing column to Konsole.

Backend enablement is `auto|1|0` through `KEEPALIVE_KONSOLE_ENABLED` and
`KEEPALIVE_ORCA_ENABLED`. Orca requires `orca-ide` plus `jq`; bare `orca` is never probed
on Linux because it commonly names the GNOME screen reader. At least one backend must be
usable for service startup.

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

The daemon is single-threaded. It interleaves one FIFO read (blocking until the next
due task, at most 5 seconds; a request wakes it at once), monotonic timer work, target validation, discovery, index publication, and stale
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

The service status checkpoint contains six TSV rows: `state`, `pid`, `version`,
`updated`, `updated_epoch`, and `pid_start`. `pid_start` pairs the published PID with
its `/proc` start-time generation, so status readers can reject PID reuse. Normal/signaled
exit writes `state=stopped`. Target checkpoints are left in place for same-login recovery.

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

String fields are converted to one line before output. Discovery is ephemeral
in-memory data; no `discovery/` runtime directory is created.

### Position-aware classifier matching

Built-in signatures inspect only command-identifying positions: process `comm`, the
resolved `/proc/PID/exe` path, `argv[0]`, and a recognized launcher's identifying
script/module/package position. Launcher option values, shell `-c` payloads, assignments,
editor/pager/grep/git arguments, and arbitrary non-file option values are excluded, so a
plain shell containing `codex` or `claude` in an argument cannot become an AI row. The
user `classifiers.tsv` registry is intentionally a legacy escape hatch: its entries match
the complete lower-case `comm exe cmdline` signature and therefore remain fully
position-independent.

## Runtime directory resolution

`ka_xdg_resolve_runtime_base` picks the base in precedence order and records the choice in
`KA_RUNTIME_SOURCE`:

```text
xdg       $XDG_RUNTIME_DIR when absolute, owned, present, and free of symlinked components
per-user  /run/user/$UID when owned, present, and free of symlinked components
fallback  /tmp/keepalive-$UID, hardened by ka_runtime_secure
```

The middle step exists because contexts that never run `pam_systemd` - `su`, `sudo -u`,
cron, non-interactive remote exec - inherit no `XDG_RUNTIME_DIR`. Without it a client there
addresses `/tmp` while the daemon listens under `/run/user/$UID`, and simply reports the
service as unavailable. Both session-managed candidates are checked for an absolute,
owned directories whose complete paths contain no symlink; the guessable `/tmp` base is additionally
created/hardened when necessary.

## Control FIFO signalling

Clients open the FIFO **read/write**. Opening a FIFO write-only blocks until a reader
appears, so a FIFO left behind by a daemon that died - it creates its own when systemd has
not, and `RemoveOnStop` covers only the socket unit's - would block the client forever with
no output. An `O_RDWR` open never blocks, so a dead daemon degrades to the ordinary
response timeout, which is bounded by `KEEPALIVE_RESPONSE_TIMEOUT_MS`.

## Tuning knob resolution

`ka_tunable NAME DEFAULT` validates an environment knob into `REPLY` and warns once per
name. Nothing interpolates a knob directly into `(( ))`: a non-numeric value is read as a
variable name and aborts the shell under `set -u`, and a numeric-looking one such as `2s`
makes the expression fail, which - with `set -e` suppressed inside an `if` condition -
silently disables the guarded work for the life of the daemon. `KEEPALIVE_SEND_GAP` is a
duration and carries its own pattern check because it is handed to `sleep`.

## Control channel policy

`ka_ipc_service_read` returns 0 for a line, 1 for the idle timeout, 2 for anything else.
The distinction matters because that read is the loop's only pacing: bash returns >128 when
`-t` expires, while EOF or a bad descriptor returns immediately and would turn the daemon
into a busy spin that never crashes and so never looks unhealthy. An abnormal read reopens
the FIFO, and five consecutive failures end the process so the service manager can restart
a working instance.

## Daemon loop failure policy

`ka_service_try` runs each periodic task and turns a failure into a warning carrying the
real status, because the loop runs under `set -e` and one failed write would otherwise
abort the daemon into a restart loop. Discovery is deliberately not wrapped: its non-zero
return is the "budget exceeded" signal the caller already handles.
`ka_service_runtime_present` ends the loop cleanly when the runtime directory disappears,
which means the session ended.

Lock contention is not a failure: a second instance logs and exits 0, so systemd does not
retry it until the start limit trips.

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

## One-shot semantics

The secondary prompt is a nudge, not a second keep-alive: `ka_scheduler_tick` fires it
only while `KA_T_SECONDARY_DONE` is 0, and a successful automatic delivery sets that to 1.
`CONFIGURE` clears it along with the countdowns, so reconfiguring re-arms the nudge. A
manual `SEND_SECONDARY` always delivers and deliberately does not consume the one-shot.

`secondary_done` is persisted in `state.tsv` but deliberately **optional** in the loader's
required-field list, so checkpoints written before the field existed still load and
default to not-yet-sent. Adding it as required would have quarantined every live record
on upgrade.

`ka_scheduler_send_enter_once` backs the detail view's `e`: it delivers a bare submit,
resets the main countdown, and sets the mode back to `MESSAGE_ENTER`. With no pending
owner it leaves the queued message untouched; when a pending owner exists, the Enter
completes that owner first (including advancing a pending MAIN rotation) so the text is
not repeated. `E` maps to `SET_MODE ENTER_ONLY`, which is an explicit set rather than a
toggle so each key reaches a known state.

### Pending-submit owner

`pending_submit` is persisted in `state.tsv` as one of `0`, `MAIN`, `SECONDARY_AUTO`,
`SECONDARY_MANUAL`, or `STALE`. The enum identifies which event owns the next Enter:
MAIN completion advances `main_index`, automatic secondary completion sets
`secondary_done`, manual secondary completion has no one-shot side effect, and STALE
completion never advances a replacement rotation. A missing field means `0`; a legacy
persisted numeric `1` is accepted as `MAIN` for compatibility.

CONFIGURE marks a nonzero owner `STALE`, resets `main_index=0`, and commits that state
before swapping the staged `messages/` directory. This state-first ordering means a
restart between commits sees the new zero-based checkpoint and a STALE Enter that cannot
advance its replacement messages, rather than pairing the old owner/index with the new
rotation. Rollback restores the old owner and old message set.

## Adaptive discovery cadence

Discovery exists to populate `AVAILABLE` rows for clients. `ka_service_discovery_interval`
sets `KA_DISCOVERY_INTERVAL` on every loop wake, fork-free: the fast interval when
`clients.seen` holds a stamp within `KEEPALIVE_CLIENT_PRESENCE_TTL`, and
`KEEPALIVE_IDLE_DISCOVERY_INTERVAL` otherwise - and unattended passes cover only the
backends listed in the 2026-10-01 section above. The TUI refreshes `clients.seen` once a
second through a builtin redirect.

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
KA_T_PENDING_SUBMIT       KA_T_LAST_DELIVERY_TIME
KA_T_LAST_DELIVERY_EVENT  KA_T_LAST_DELIVERY_RESULT
KA_T_LAST_DELIVERY_DETAIL
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
secondary_done
secondary_message_file
last_seen
reason
pending_submit
last_delivery_time
last_delivery_event
last_delivery_result
last_delivery_detail
```

The secondary prompt is a literal versioned companion named by the
`secondary_message_file` row. Legacy checkpoints without that row still use
`secondary_message`. Main messages are literal numbered files under `messages/`, and
`main_index` is zero-based.

Load-time validation is fail-closed before array registration. It requires every
known field exactly once; rejects extra columns in known rows; validates non-empty
identity/display fields, service/path shape, positive PID/start-time/interval
values, exact enums/booleans, remaining-time bounds, and `main_index`; binds the
stored UUID to the target-directory basename; and requires non-symlink state,
versioned secondary-message payload, message-directory, and canonical contiguous message files. Unknown
field names remain ignorable for forward compatibility. Interval fields are bounded to
`1..999999999` seconds. Scalar readers count UTF-8 code points with a locale-independent
bounded read, not bytes; this keeps message limits consistent under `LC_ALL=C` and UTF-8
locales. Delivery metadata is display-only and malformed values are cleared rather than
quarantining an otherwise valid target.

Any rejected top-level target entry is moved into a uniquely created
`quarantine/<safe basename>.<suffix>/record` wrapper before the daemon loop starts.
The wrapper also receives `quarantine_reason`, `quarantined_at`, and the matching
event log when one exists. The loader never follows target/message symlinks.

`state.tsv`, scalar profile fields, service state, and the merged index use same-directory
temporary-file rename. `state.tsv` commits the name of a completely written versioned
secondary-message payload. Message-directory, target checkpoint, and multi-file profile
replacement remain separate operations; see `RISKS.md` for the resulting crash windows
and compensating CONFIGURE rollback.

## Merged client index

`index.tsv` is regenerated atomically after every request, every second while a client
is attached, and every `KEEPALIVE_STATUS_INTERVAL` otherwise; an identical payload is not
rewritten. It first contains every monitored target, then every currently discovered
UUID that has no monitored record.

Its 21 positional columns are:

```text
1  UUID                 2  TYPE                 3  NAME
4  DIRECTORY            5  STATUS               6  MAIN_REMAIN
7  MAIN_INTERVAL        8  SECONDARY_ENABLED   9  SECONDARY_REMAIN
10 SECONDARY_INTERVAL   11 MODE                12 NOTIFICATIONS
13 LAST_SEEN             14 REASON              15 BACKEND
16 NEXT_MAIN             17 NEXT_SECONDARY      18 LAST_DELIVERY_TIME
19 LAST_DELIVERY_EVENT   20 LAST_DELIVERY_RESULT 21 LAST_DELIVERY_DETAIL
```

Columns 16-21 are appended compatibility extensions; readers of the original first 15
columns remain valid, while missing extension fields mean no deadline or no delivery
metadata.

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
6. Daemon reads request fields, dispatches, and creates `responses/<id>/`.
7. Daemon writes `message` first and `status` (`OK`/`ERROR`) last. A successful completed
   command remains `OK` if index publication fails afterward; its message carries a
   deferred-publication warning and the service retries at most once per second.
8. `REFRESH` remains `OK` when discovery or target validation fails, but appends a warning
   naming the failed pass and retains each backend's last complete snapshot.
9. Client polls for `status`, prints `STATUS<TAB>message`, removes the response directory,
   and times out after 8 seconds by default. On a timeout the client renames the request
   to `<id>.cancelled`; the daemon renames it to `<id>.claimed` before reading any of it.
   `rename(2)` succeeds for exactly one side, so a cancelled request is never executed,
   and a client that lost the race reports that the daemon may still complete it.
10. Daemon removes the consumed request directory after responding.

The daemon opens the FIFO read/write to avoid EOF busy-spinning. If the FIFO is
absent, a client asks `systemctl --user start keepalive.socket`; the service can
also create/open a FIFO directly for tests. Request/response directories older
than one hour are cleaned hourly.

Operations:

| Operation | Effect |
|---|---|
| `PING` | Liveness response only. |
| `REFRESH` | Rediscover and validate monitored targets; answer `OK` with a warning and keep the last good snapshot if either pass fails. |
| `CREATE` | Create `ACTIVE` target from discovery and update profile. |
| `CONFIGURE` | Replace selected target settings/reset timers and update profile. |
| `DELETE` | Remove selected target directory, arrays, and log. |
| `TOGGLE_PAUSE` | `ACTIVE` ↔ `PAUSED`. |
| `TOGGLE_MODE` | `MESSAGE_ENTER` ↔ `ENTER_ONLY`. |
| `RESET_MAIN` | Restore main remaining to configured interval. |
| `SEND_MAIN` | Manual main delivery and main timer reset; transport failure returns `ERROR`. |
| `SEND_SECONDARY` | Manual secondary delivery and secondary timer reset; transport failure returns `ERROR`. Does not consume the one-shot. |
| `SEND_ENTER` | Deliver one submit sequence now, reset the main timer, and return the target to `MESSAGE_ENTER`. |
| `SET_MODE` | Set delivery mode to the `value` file's contents rather than toggling. |

`status --json` is not an IPC operation. It is a read-only, presence-free snapshot reader:
it validates existing `service.state` and `index.tsv`, never activates the socket, never
creates configuration/runtime state, and never writes `clients.seen`. It matches
`pid_start` to the recorded PID (or uses the legacy daemon command-line fallback) before
reporting `service.online`.

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
  -> save target and publish index (or mark publication stale and warn without changing a successful command to ERROR)
  -> return IPC ERROR only for a failed command or transport operation
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
- installed under the standard user `sockets.target`, independent of the desktop;
- explicitly activates `keepalive.service`.

`keepalive.service`:

- `ExecStart=%h/.local/bin/keepalive --service`;
- static (not enabled directly), with `BindsTo=`, `PartOf=`, and `After=` on
  `keepalive.socket` so stopping the endpoint stops the daemon while a daemon crash leaves
  activation available;
- `Restart=on-failure`, two-second delay;
- `UMask=0077`;
- namespace-free hardening only: `NoNewPrivileges=yes`, `RestrictRealtime=yes`,
  `RestrictNamespaces=yes`, `LockPersonality=yes`,
  `SystemCallArchitectures=native`, `RestrictAddressFamilies=AF_UNIX`;
- user-manager scoped, without a KDE or graphical-session dependency.

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

## TUI line erasure

`ka_tui_frame_begin` positions the cursor and `ka_tui_frame_end` emits `ED 0`, which
clears only from the cursor downward. Neither erases the tail of a line the new frame
overwrites with shorter content, so every drawn line ends with `EL 0` instead. Any change
in frame height, such as a new log event or an added wizard message, otherwise leaves the
previous line's tail visible beside the new text.

The rewrite applies to screen-drawing `printf` format strings only.
`ka_tui_sort_index_rows` pipes TSV into `sort` and `printf -v` builds strings; escapes
there would corrupt data.

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
`MAIN`, `SECONDARY`, and `ENTER`. `ENTER` records the one-shot `e` delivery and an
automatic `ENTER_ONLY` main delivery; its detail is `[ENTER]`. Text is collapsed to one
line. Logs are appended by the daemon and read with `tail`/`cat` by clients. Deleting a
target deletes its log.
