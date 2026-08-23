# Changelog

All notable changes to Keep Alive Manager are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/TeleVoyant/keepalive/releases/tag/v1.0.0
