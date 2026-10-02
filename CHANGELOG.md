# Changelog

All notable changes to Keep Alive Manager are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-10-02


A correctness, hardening, and visibility release on top of 1.1.0, from an eight-part audit
and three proofreading rounds: event-scoped pending submits, position-aware AI detection,
safer IPC/profile/log/installer paths, sanitized output, `keepalive configure`,
read-only `keepalive status --json`, next-send and last-delivery visibility, and
tag-driven releases.

### Added

- **CLI features:** add scriptable `configure UUID [options]`, read-only and
  presence-free `status --json`, and published next-send/last-delivery data in list and
  JSON output.
- **Release tooling:** add tag-driven archive, checksum, release-note, and GitHub Release
  automation, plus an idempotent version-bump helper and CI aggregate-summary checks.

### Changed

- **Scheduler correctness:** persist event-scoped pending-submit ownership (`MAIN`,
  `SECONDARY_AUTO`, `SECONDARY_MANUAL`, or `STALE`), complete owed submits in order, and
  commit a `STALE` owner before a CONFIGURE message swap; legacy persisted `1` loads as
  `MAIN`.
- **Discovery and classifier:** make built-in matching position-aware, bound Orca fields,
  classify a complete shell transition as identity loss, and retain complete snapshots
  when a backend pass or its budget fails.
- **IPC/profile/logging hardening:** bound scalar reads in UTF-8 code points, protect
  profile swaps and logs from unsafe paths, preserve successful command results when index
  publication is deferred, warn on partial REFRESH results, and cancel timed-out requests
  atomically (a rename-based claim, so a cancelled request is never executed late).
- **Output and CLI strictness:** sanitize human output and notification markup, preserve
  valid JSON/control semantics, reject empty UUIDs and extra/unknown arguments, and report
  unknown logs with an actionable error.
- **Performance:** keep hot-path sanitizer fronts and XDG safety checks fork-light while
  retaining ownership, mode, and descriptor validation.

### Fixed

- **Installer/uninstaller safety:** canonicalize and validate managed roots and exact unit
  entries, refuse unsafe symlink/world-writable paths, preserve rollback state, add opt-in
  runtime purge, and keep installed documentation/package payloads consistent.
- **CI and tests:** make PTY capture and aggregate summaries deterministic, add the final
  IO/output/status/state-delivery regressions, and cover classifier option-value and
  pending-submit compatibility cases. The suite grows from 1040 assertions in 27 files to
  1519 assertions in 31 files.

### Security

- Human-facing terminal, log, profile, list, response, and notification text is sanitized
  before display; malformed bytes, C0/C1 controls, bidi controls, and markup cannot become
  terminal or notification control sequences.
- Request, response, profile, state, log, runtime, and installer paths fail closed on
  FIFOs, symlinks, unsafe ownership/modes, and unbounded values.

### Performance

- `keepalive list` sends one REFRESH instead of PING plus REFRESH (about 191 ms to 136 ms
  median in an isolated benchmark), and the detail view caches its text and log tail
  (about 5.7x less work per frame, now below the manager view).
- The human-output sanitizer splits a tiny fast-path front from its byte scanner, because
  Bash copies a function's whole body on every call: about 5x cheaper per call on the
  TUI frame path.
- The new installer-grade configuration path checks are memoized per operation and read
  metadata with one `stat` per walk, so they add about 15 ms per CLI command instead of
  the roughly 1.6 s an unmemoized version cost.
- Measured on the development host after installing: daemon idle CPU 0.20% over 60 s
  (1.1.0: 0.30%), 11 MB RSS.

## [1.1.0] - 2026-10-01

Orca support, desktop-neutral systemd activation, a hardening pass, a resource pass that
takes the idle daemon from about 2% of a core to under 0.1% (and a live single-target
Orca setup from 7.4% to 1.2%), and updates that keep running keep-alives.

### Added

- Orca terminal backend for agents launched inside Orca, discovered through the
  `orca-ide` JSON CLI and delivered through its atomic text-plus-Enter operation.
- Exact Orca identity binding across runtime, handle, PTY, process incarnation,
  worktree, execution host, tab, leaf, and agent identity, revalidated before every send.
- Backend-neutral transport dispatch plus independent per-backend discovery snapshots,
  so a schema or availability failure in Orca cannot erase healthy Konsole rows.
- Orca mock/unit coverage and a real daemon/FIFO/client integration test.
- Cross-distribution portability, transactional-install, runtime-path, D-Bus-address,
  IPC failure, and unit-lifecycle coverage. The complete suite now exercises 1040
  assertions across 27 files when optional dependencies exist.
- Updates keep running keep-alives. The installer records every monitored target before
  swapping the code, restarts an active daemon gracefully, waits for the new one, and
  reports each target that reloaded, changed state, or did not come back; it warns about
  a daemon that was not started by systemd. An open manager TUI restarts itself on the
  updated installation once the daemon has, returning to the selected row.

### Changed

- User socket activation now uses `sockets.target` instead of
  `graphical-session.target`, so KDE, GNOME, other desktops, SSH, and headless systemd
  user sessions share one lifecycle. The static service is bound one-way to its socket.
- Installation now preflights the user manager, requires shell/manager HOME and XDG
  agreement, canonicalizes complete unit roots, remembers prior custom roots, rejects
  source/config overlap, migrates stale graphical-session links, stages source and unit
  replacements transactionally, reports incomplete rollback, and preserves active-daemon
  restart behavior.
- Uninstall now requires a confirmed unit stop before deleting executable files; an
  explicit `--force` recovery path remains available when the user manager is unavailable.
- Runtime-directory selection rejects relative, foreign-owned, group/world-writable, or symlinked
  `XDG_RUNTIME_DIR` values and can derive the standard systemd user-bus address when the
  login environment omitted it.
- The unit targets systemd 235 and later. `RestrictSUIDSGID` (added in systemd 242) was
  removed; `NoNewPrivileges` remains, so the unprivileged daemon cannot gain privileges
  through set-user-ID or set-group-ID executables on older supported managers.
- Terminal-specific Orca commands, JSON fields, and error mappings are isolated in one
  version-tolerant adapter. Unknown schemas fail closed and are treated as transient
  during live validation, making future Orca CLI changes localized and safe.
- Checkpoints and published list rows carry a backend discriminator; checkpoints written
  before this field continue to load as Konsole targets.
- `keepalive doctor` reports Konsole and Orca independently and requires at least one
  usable terminal backend.

### Fixed

- Definitive pre-send identity failures now return their exact backend reason to manual
  CLI/TUI callers instead of the generic `main send failed` fallback.
- Scalar writes can no longer report success by moving their temporary file inside a
  directory at the destination path. FIFO writes, response writes, lock setup, profile
  replacement, and failed CLI-create cleanup now propagate errors without silencing the
  daemon shell's stderr.
- Target checkpoints atomically reference versioned secondary-message payloads;
  CONFIGURE compensates to the exact prior target on a reported profile/state failure,
  mode/timer mutations report persistence errors, and interrupted profile swaps recover
  their rollback directory before defaults can be recreated.
- Informational CLI flags no longer hide preceding unknown arguments, request-creation
  diagnostics survive without a subshell, and the ASCII progress-bar assertion now tests
  real bytes instead of relying on an unsupported `tr` character class.
- An attached TUI is now actually seen as a client. Its presence stamp carried a
  terminal erase sequence that the daemon rejected, so discovery never left the
  unattended cadence while someone was watching; the daemon also accepts old stamps.
- A stop no longer cuts a delivery in half. TERM during a send used to land between the
  message and its Enter (or after the timer event was consumed); the daemon now finishes
  the delivery and exits between loop iterations, and `KillMode=mixed` keeps its helper
  alive. `KEEPALIVE_SEND_GAP` is now actually capped (10 s) so a stop always completes.
- A control request arriving just as the daemon's FIFO read timed out was dropped: Bash
  reports the timeout but keeps the bytes it already consumed, and the remainder was then
  rejected as a malformed line. The client waited out its full timeout (the "TUI takes
  8 seconds to open" symptom). Latent since 1.0.0; the daemon now completes the line.
- DELETE reports failure instead of `OK` when the target directory cannot be removed.
- Truncated display names no longer split a multibyte character.
- A discovery snapshot taken before a monotonic rollback is no longer trusted as fresh.
- Crash debris is collected at startup: orphaned versioned secondary-message files,
  interrupted atomic-write temporaries, and log-trim sidecars.

### Performance

Measured before/after in isolated systemd user scopes with the mocks (two alternating
62-second repetitions per state; full method in `.agents/DEVELOPMENT.md`):

| State | CPU before | CPU after | Context switches/min |
|---|---:|---:|---:|
| Idle, nothing monitored | 2.09% | 0.08% | 557 → 24 |
| Client attached | 5.42% | 2.54% | 568 → 265 |
| Two active Konsole targets | 4.92% | 3.47% | 1134 → 424 |
| Two active Orca targets | 2.50% | 0.63% | 799 → 111 |
| Two active Konsole targets + client | 8.26% | 4.94% | 941 → 532 |

Idle TUI CPU fell from 7.5% to 2.8%, `keepalive list` from 519 to 388 ms, and
`keepalive pause` from 1006 to 683 ms. Daemon RSS rose 4-8% (about 0.5 MiB). The changes:

- The daemon sleeps until its next due task instead of polling the control FIFO five
  times a second; the one-second tick runs only while a countdown is active, and the
  index is republished every second only while a client is attached.
- Unattended, discovery runs only for a backend whose snapshot health actually reuses
  (Orca by default); periodic Orca discovery backs off exponentially, to a minute, while
  the Orca CLI keeps failing.
- An identical index is not rewritten. Atomic writes start one process (the rename)
  instead of four.
- The `/proc` classifier, Konsole discovery, health checks, and the TUI frame no longer
  fork per field; the executable lookup is cached per process image, discovery parsing
  uses builtin regexes, and the TUI sorts only when row order can change.
- Each Orca list and show response is validated and projected by one `jq` run instead
  of two, still failing closed on any unexpected document.
- The CLI waits for responses without starting a `sleep` process per poll.
- The service unit runs the daemon at `Nice=10` with batch CPU scheduling, idle I/O
  priority, and 50 ms timer slack; none of these needs cgroup delegation.

## [1.0.0] - 2026-08-23

First public release. Keep Alive Manager keeps long-running terminal AI clients from
idling out by injecting a configured message through Konsole's D-Bus `sendText`, with a
per-user daemon that owns the timers and a disposable TUI client that can attach and
detach without disturbing them.

Development before this tag happened in a private repository over nine commits. Rather
than invent version numbers for work that was never released, that history is
consolidated here.

### Added

- Persistent per-user daemon (`systemd --user`) managing any number of Konsole AI
  sessions with independent countdowns, surviving client exit, pause, suspend, and
  daemon restart within a login session.
- Attachable TUI client with a creation wizard, live countdown view, per-target event
  log, and configuration editor. Closing a client never stops a keep-alive.
- Automatic discovery and classification of recognized AI CLIs (Claude Code, Codex,
  Kimi, and others) via a user-extensible pattern file.
- Strict target identity: Konsole session UUID, terminal PID, AI PID and start time, and
  foreground ancestry must all still match before any send. A lost identity becomes
  `UNAVAILABLE` and is never silently rebound to a replacement terminal.
- Message rotation with a canonical order, plus Enter-only modes: `e` sends a single
  Enter and resumes the normal message rotation, `E` switches to Enter-only from then on.
- Optional one-shot secondary prompt, delivered once rather than repeating.
- Scriptable CLI (`list`, `add`, `pause`, `resume`, `delete`, `refresh`, `send`,
  `status`) with `--json` output for automation.
- Presentation modes for terminals without Nerd Fonts or color: `--no-icons`,
  `--no-color`, `--ascii`, and `NO_COLOR` support, each a complete rendering path.
- Per-target runtime-only event logs, bounded in size, that disappear at logout.
- Desktop notifications for delivery failures and lost targets.
- Configuration surface of documented environment knobs covering cadences, timeouts,
  budgets, and retention.
- Test suite of 328 assertions across 14 files, dependency-free apart from an optional
  `python3` used to drive a real pseudo-terminal, plus `scripts/dev-check.sh`.

### Changed

- Daemon CPU with monitored targets reduced by roughly five times. Discovery now backs
  off on client presence alone rather than target count, pure string helpers return
  through `REPLY` instead of a subshell, and a countdown tick marks a target dirty
  instead of rewriting its checkpoint every second.
- Discovery is bounded by a per-pass time budget, so a degraded D-Bus cannot stall the
  scheduler and silently freeze every countdown.
- Health validation reuses the discovery snapshot only while it is fresh, falling back to
  a live check past `KEEPALIVE_SNAPSHOT_MAX_AGE`.
- Transient D-Bus failures are debounced rather than immediately destroying a target.
- Refusal reasons are propagated from the daemon to clients instead of failing silently.
- Runtime directory resolution follows a documented precedence with a hardened fallback,
  so the daemon works over SSH and in sessions without `pam_systemd`.
- Invalid tuning knobs warn once and fall back to their default rather than producing a
  degenerate loop.

### Fixed

- `PrivateTmp=yes` in the service unit put the daemon in a mount namespace, which broke
  `/proc/PID/cwd` and `/proc/PID/exe` resolution and made every session display as
  `unknown`. The unit now hardens without namespacing, and carries a comment naming the
  directives that must never return.
- The creation wizard silently rejected custom messages and intervals, so only default
  values worked. Its prompt helper returned the prompt text on stdout instead of the
  typed value.
- Unrecognized escape sequences decoded as a bare Escape, so arrow, function, keypad, and
  bracketed-paste keys immediately exited the TUI. Key decoding is now byte-by-byte.
- A key typed immediately after Escape was swallowed.
- Cancelling the wizard exited the whole client, because a non-zero return escaped the
  action loop under `set -e`.
- Frames that redrew shorter content over longer content left stale tails, most visibly a
  duplicated key-hint footer.
- A clean daemon stop was logged as a unit failure.
- A partially delivered message is retried as owed rather than counted as sent.

### Security

- The control FIFO carries only short request identifiers. Messages and configuration
  travel through private request directories under `$XDG_RUNTIME_DIR` and are validated
  as data, never evaluated as shell code.
- The daemon is strictly per-user and never runs as root.
- Runtime state is created under `umask 077`, and the non-XDG fallback directory is
  ownership-checked and hardened before use.

[1.1.0]: https://github.com/TeleVoyant/keepalive/releases/tag/v1.1.0
[1.0.0]: https://github.com/TeleVoyant/keepalive/releases/tag/v1.0.0

[1.1.1]: https://github.com/TeleVoyant/keepalive/releases/tag/v1.1.1
