# Testing

The suite is plain Bash. It needs no Bats or test framework. Python is optional for the
pseudo-terminal fixtures, and `jq` is optional for the Orca adapter tests; those files
skip cleanly when their optional dependency is absent. That constraint is deliberate:
the tool ships as Bash to hosts that may have very little else installed.

**1040 assertions across 27 files** when Python and `jq` are present (one ownership case
skips unless the suite runs as root).

## Running

Everything, in the order CI runs it:

```bash
./scripts/dev-check.sh
```

It must end with `ALL VALIDATION CHECKS PASSED`. The stages are Bash syntax, optional
ShellCheck, version consistency, the test suite, and static systemd unit verification.

Just the tests:

```bash
./tests/run.sh
```

One file, which is what you want while iterating:

```bash
bash tests/test_scheduler.sh
```

Each file prints one `ok` line per assertion and a trailing count, so a single file is
readable output rather than a summary you have to decode.

## Isolation

Every `test_*.sh` runs against a temporary `HOME`, `XDG_CONFIG_HOME`, and
`XDG_RUNTIME_DIR` created by `test_env_setup` in `tests/testlib.sh`. Nothing touches your
real profile, your installed units, or a running daemon. Files that start a background
daemon install an `EXIT` trap that kills it.

The shared setup explicitly disables Orca. Orca tests opt back in with the repository's
mock executable, so installing `orca-ide` on a developer workstation can never make a
normal test enumerate or send to live agents.

That trap matters more than it looks. An orphaned `keepalive --service` is adopted by
systemd when its parent dies, keeps polling indefinitely, and silently inflates any CPU
measurement taken afterwards. If you write a scratch script that starts a daemon, give it
a trap - the committed tests all have one.

## What each file covers

| File | Assertions | Covers |
|---|---:|---|
| `test_common.sh` | 39 | Duration helpers, collision-safe atomic writes, shell-metacharacter literal handling, injectable monotonic reads, tunable validation and one-shot warnings. |
| `test_classifier.sh` | 10 | Recognized wrapper signatures, negative matching, process ancestry, CRLF-tolerant pattern files, and refusal of a pattern that cannot compile. |
| `test_profile.sh` | 12 | Default profile creation, updates, literal message storage, canonical contiguous message numbering. |
| `test_state.sh` | 41 | Mutation-free rejection of malformed CREATE/CONFIGURE, the create/pause/resume/unavailable/delete lifecycle, legacy checkpoint compatibility, transient health timeouts, independent log cleanup, and new-UUID no-reattach behavior. |
| `test_scheduler.sh` | 54 | Main rotation, Enter-only queue preservation, main and secondary transport failures, validation timeouts, timer independence, suspend-gap and backward-clock preservation, one-shot secondary, and owed-submit retry. |
| `test_service_integration.sh` | 24 | A real background daemon, real FIFO, and real client processes against a mocked qdbus: create, send, send failure, send timeout, target loss, and replacement UUID, end to end. |
| `test_ipc.sh` | 15 | Multiple concurrent request IDs through one FIFO, response routing, timeout behavior, and a request line split across a read timeout being completed rather than dropped. |
| `test_konsole_mock.sh` | 16 | Mocked Konsole service/path/UUID/PID discovery, strict validation, qdbus timeout classification, and notification deadlines. |
| `test_orca_mock.sh` | 50 | Orca CLI/schema normalization, exact multi-field identity, non-destructive schema drift, deadlines, atomic delivery, checkpoint validation, transport dispatch, and per-backend snapshot isolation. Skips without `jq`. |
| `test_orca_service_integration.sh` | 10 | A real Orca-only daemon, FIFO, and public clients against the mock: discover, create, atomic send, transient outage, and sticky incarnation replacement. Skips without `jq`. |
| `test_recovery.sh` | 11 | Same-login daemon restart countdown recovery, deferred transient identity validation, and dirty-flush persistence. |
| `test_recovery_validation.sh` | 18 | Strict checkpoint schema and range validation, symlink rejection, quarantine diagnostics, and event-log preservation. |
| `test_tui_primitives.sh` | 74 | ASCII and no-icon rendering, first-frame/view-transition/same-view/resize clearing, width-exact frames, safe truncation, control-byte stripping, non-collapsing TSV splitting, 7-bit glyph selection, segment-bar width accounting, and key decoding including unrecognized sequences and Escape pushback. |
| `test_tui_pty.sh` | 14 | The real client driven through a pseudo-terminal. Skips cleanly without `python3`. |
| `test_failure_propagation.sh` | 27 | Runtime/request/response/index/lock failure propagation, lock-symlink refusal, descriptor error handling, CLI request cleanup, and timeout output. |
| `test_install_layout.sh` | 7 | Non-root install and uninstall layout against a mocked `systemctl`. |
| `test_install_lifecycle.sh` | 25 | Manager-scoped XDG paths, graphical-link migration, installed-tree updates, active-daemon restart, transactional rollback, and profile retention. |
| `test_install_safety.sh` | 81 | Fail-closed manager probes, path-overlap refusal, unrecognized-tree preservation, exact link rollback, reserved-path checks, and daemon-reload error propagation. |
| `test_portability.sh` | 39 | Unsafe runtime rejection, `/run/user` fallback, absolute config rules, D-Bus address escaping, and HOME-free informational modes. |
| `test_runtime_hardening.sh` | 63 | Runtime-component symlink refusal, ownership/mode repair, permission failure propagation, and atomic destination safety. |
| `test_state_hardening.sh` | 46 | Versioned secondary payloads, client-side configuration seeding, dirty flush errors, target symlink refusal, interrupted-message recovery, and index commit safety. |
| `test_systemd_units.sh` | 16 | Desktop-neutral socket target, static service dependencies, the systemd 235 directive floor, low-priority scheduling (`Nice`, batch CPU, idle I/O, timer slack, never `SCHED_IDLE`), `KillMode=mixed`, and the absence of cgroup caps and mount-namespace directives. |
| `test_loop_pacing.sh` | 60 | Millisecond monotonic parsing and bounds, presence-stamp parsing (bare, legacy escape-suffixed, overflow), attended/unattended cadence and per-backend discovery selection, Orca discovery backoff and its reset, a real idle daemon's wakeup budget with prompt IPC, no false gap events for paused-only targets, and graceful stop both idle and mid-delivery. |
| `test_atomic_io.sh` | 108 | Descriptor-held atomic writes (content, 0600 modes, no debris, subshells, caller noclobber), planted-FIFO and close-time symlink-swap safety, content-compared index publication and tamper repair, startup companion pruning and temp sweeping under validated roots, delete failure, and fork-free `ka_sleep`. |
| `test_fork_free_helpers.sh` | 95 | `/proc` `_set` helpers against their printing forms, the executable cache (no repeat `readlink`, exec invalidation, bound), discovery running in the caller's shell, dbus-send/qdbus service and session-path parsing, Orca single-`jq` fail-closed handling, multibyte-safe truncation, and the TUI sort cache. |
| `test_update_reload.sh` | 83 | The installer's target manifest, lock-descriptor daemon identity, bounded new-daemon wait, and reload report; a real daemon restarted with ACTIVE and PAUSED targets recovering countdowns, rotation, and SERVICE events; installer warnings; the send-gap cap; absolute invocation; and TUI update detection, preflight failure, and row restoration. |
| `test_function_comments.sh` | 2 | Every function carries a `# Role:` comment, and no function uses a self-referential `local`. |

## The pseudo-terminal tests

`test_tui_pty.sh` is the only test that exercises key handling, navigation, and `set -e`
behavior the way a person does. It exists because three real defects once passed a fully
green suite: unrecognized escape sequences exited the client, a key typed immediately
after Escape was swallowed, and cancelling the wizard exited with status 1. None of them
were reachable by calling functions directly.

Two fixtures support it:

- **`tests/fixtures/pty-drive.py`** runs a command under a real `pty.fork()` with a
  scripted key sequence. Keys may be literal text, a named key such as `PGDN` or `F5`, or
  `@text`, which **waits until that text appears** before continuing. Waiting on output
  instead of sleeping is what makes these tests deterministic; a fixed delay races
  whatever the client is doing. It distinguishes `START-TIMEOUT` (the client never drew,
  so the environment was slow) from `WAIT-TIMEOUT` (a key produced the wrong result),
  which lets the test retry the first without masking the second.
- **`tests/fixtures/vt-render.py`** replays a capture through a minimal VT - cursor
  positioning, erase-in-display, erase-in-line, scrolling - to produce the screen a user
  would actually see. This catches the class of bug where a frame redraws shorter content
  over longer content and leaves the old tail visible, which is invisible to any test that
  only inspects the byte stream.

Both are optional. Without `python3` the file skips and the rest of the suite is
unaffected.

## Writing a test

Source the library, set up the environment, assert, finish:

```bash
#!/usr/bin/env bash
# One line saying what this file covers.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

assert_eq 'expected' "$(some_function)" 'description of the behavior'
assert_true 'the file was created' test -f "$TEST_TMP/thing"

test_finish
```

Conventions worth knowing, each of which has cost time before:

- `assert_true` takes a **command**, not a `[[ ]]` expression. `[[` is shell syntax, not a
  command, and passing it produces a confusing failure.
- Under `set -e`, a deliberately non-zero call must be guarded - `foo || true` - or the
  file aborts before your assertion runs.
- Command substitution runs in a subshell, so state a function sets in a global (an
  associative array, `REPLY`) does not survive `$(...)`. Call it directly and read the
  global.
- Assert on rendered width, not byte length, when checking layout. ANSI escapes are bytes
  that occupy no cells.

## What these tests cannot prove

The suite drives mocked qdbus and Orca CLI endpoints, so it runs without attaching to a
real terminal. Those mocks are stand-ins, not proof. They cannot exercise:

- a real systemd user-manager login/logout, socket-activation, or lingering lifecycle;
- a live user D-Bus;
- Konsole's actual `sendText` behavior;
- a real Orca terminal-send receipt or a future Orca release's JSON contract;
- real process trees for every installed AI CLI version;
- a desktop notification server;
- Nerd Font cell rendering;
- suspend and resume on a specific kernel and session stack.

Work through the live integration checklist in
[`MAINTENANCE.md`](MAINTENANCE.md#live-integration-test-checklist) in both a
non-KDE systemd user session and, for the Konsole backend, a real KDE/Konsole session.
Use a disposable Orca agent for live Orca delivery before treating both backends as
qualified. Release 1.0.0's Konsole path was validated on KDE; see
[`VALIDATION.md`](VALIDATION.md).

## Continuous integration

`.github/workflows/ci.yml` runs `scripts/dev-check.sh` as root in Ubuntu, Debian, Fedora,
and Arch containers, plus a separate blocking ShellCheck job. Root intentionally exercises
the `runuser` and ownership branches. Container jobs verify shell behavior and unit parsing;
they do not pretend to provide a booted systemd user manager. The live qualification list
below remains the gate for real `%t` FIFO activation and login/logout lifecycle behavior.

Reading `.shellcheckrc` is worthwhile before adding to it. Six codes are disabled
project-wide with their reasoning recorded, and one of them matters beyond style: SC2004
suggests dropping `$` from arithmetic subscripts, which is correct for indexed arrays and
actively wrong here, because nearly every subscript in this codebase belongs to an
associative array where the subscript is a string:

```bash
declare -A a; k=mykey; a[$k]=5
$(( a[$k] - 1 ))   #  4  correct
$(( a[k]  - 1 ))   # -1  reads the literal key "k"
```

Taking that advice would silently corrupt every target lookup in the daemon.
