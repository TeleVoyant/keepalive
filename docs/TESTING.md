# Testing

The suite is plain Bash. It needs no Bats, no test framework, and - apart from two
optional fixtures - no Python. That constraint is deliberate: the tool ships as Bash to
hosts that may have very little else installed, and a test suite that cannot run there is
not much use.

**328 assertions across 14 files.**

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

That trap matters more than it looks. An orphaned `keepalive --service` is adopted by
systemd when its parent dies, keeps polling indefinitely, and silently inflates any CPU
measurement taken afterwards. If you write a scratch script that starts a daemon, give it
a trap - the committed tests all have one.

## What each file covers

| File | Assertions | Covers |
|---|---:|---|
| `test_common.sh` | 36 | Duration helpers, scalar safety, shell-metacharacter literal handling, injectable monotonic reads, tunable validation and one-shot warnings. |
| `test_classifier.sh` | 10 | Recognized wrapper signatures, negative matching, process ancestry, CRLF-tolerant pattern files, and refusal of a pattern that cannot compile. |
| `test_profile.sh` | 12 | Default profile creation, updates, literal message storage, canonical contiguous message numbering. |
| `test_state.sh` | 40 | Mutation-free rejection of malformed CREATE/CONFIGURE, the create/pause/resume/unavailable/delete lifecycle, transient health timeouts, independent log cleanup, and new-UUID no-reattach behavior. |
| `test_scheduler.sh` | 54 | Main rotation, Enter-only queue preservation, main and secondary transport failures, validation timeouts, timer independence, suspend-gap and backward-clock preservation, one-shot secondary, and owed-submit retry. |
| `test_service_integration.sh` | 24 | A real background daemon, real FIFO, and real client processes against a mocked qdbus: create, send, send failure, send timeout, target loss, and replacement UUID, end to end. |
| `test_ipc.sh` | 12 | Multiple concurrent request IDs through one FIFO, response routing, and timeout behavior. |
| `test_konsole_mock.sh` | 16 | Mocked Konsole service/path/UUID/PID discovery, strict validation, qdbus timeout classification, and notification deadlines. |
| `test_recovery.sh` | 11 | Same-login daemon restart countdown recovery, deferred transient identity validation, and dirty-flush persistence. |
| `test_recovery_validation.sh` | 18 | Strict checkpoint schema and range validation, symlink rejection, quarantine diagnostics, and event-log preservation. |
| `test_tui_primitives.sh` | 74 | ASCII and no-icon rendering, first-frame/view-transition/same-view/resize clearing, width-exact frames, safe truncation, control-byte stripping, non-collapsing TSV splitting, 7-bit glyph selection, segment-bar width accounting, and key decoding including unrecognized sequences and Escape pushback. |
| `test_tui_pty.sh` | 14 | The real client driven through a pseudo-terminal. Skips cleanly without `python3`. |
| `test_install_layout.sh` | 5 | Non-root install and uninstall layout against a mocked `systemctl`. |
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

The suite drives a mocked qdbus endpoint, so it runs anywhere. That mock is a stand-in,
not a proof. It cannot exercise:

- the Plasma graphical-session lifecycle;
- a live user D-Bus;
- Konsole's actual `sendText` behavior;
- real process trees for every installed AI CLI version;
- a desktop notification server;
- Nerd Font cell rendering;
- suspend and resume on a specific kernel and session stack.

Work through the live integration checklist in
[`MAINTENANCE.md`](MAINTENANCE.md#live-integration-test-checklist) on a real
KDE/Konsole workstation before treating a release as qualified. Release 1.0.0 was
validated that way; see [`VALIDATION.md`](VALIDATION.md).

## Continuous integration

`.github/workflows/ci.yml` runs `scripts/dev-check.sh` as the blocking job. ShellCheck
runs as a separate advisory job with `continue-on-error`, because the codebase has never
been verified against it - no ShellCheck is available in the development environment, so
making it blocking would fail CI on findings nobody has triaged. Treat its output as a
backlog, not a gate.
