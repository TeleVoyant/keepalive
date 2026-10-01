# Contributing

Thanks for looking at Keep Alive Manager. This file covers the things that are specific to
this project; the general shape of a pull request is the usual one.

## Before you start

Read [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md). It lists the safety invariants that
contributors must preserve, and several of them are not obvious from reading the code -
in particular the rules around target identity and automatic reattachment, which exist to
prevent typing into somebody else's shell.

## Validation

Every change must pass:

```bash
./scripts/dev-check.sh
```

It must end with `ALL VALIDATION CHECKS PASSED`. This runs Bash syntax checks, ShellCheck,
version consistency, the full 484-assertion/20-file suite, and static systemd unit verification.
CI gates on the same checks.

ShellCheck must stay at zero findings. Before adding a code to `.shellcheckrc`, read the
justifications already there - particularly SC2004, which is disabled because following it
would corrupt associative-array lookups rather than because it is noisy.

Anything touching a terminal backend, the TUI, or the scheduler also needs a pass through the
live integration checklist in
[`docs/MAINTENANCE.md`](docs/MAINTENANCE.md#live-integration-test-checklist) against a real
systemd user session. Use a KDE/Konsole session for Konsole D-Bus changes and a disposable
Orca agent for Orca changes; systemd lifecycle work also needs a non-KDE or headless pass. The
mocks cannot stand in for those contracts, and live validation is where several serious
defects in this project's history were actually caught.

## Conventions the checks enforce

**Every function carries an adjacent `# Role:` comment.** A test enforces this. Write what
the function is for, and if the implementation is non-obvious, why it is written that way
rather than the obvious way. The comment is the maintenance record.

**No self-referential `local`.** This is also tested:

```bash
local dir=$1 file="$dir/state.tsv"   # WRONG
```

Bash expands every assignment word before creating any of the locals, so `$dir` there is
whatever was in scope from a caller, not the value being assigned on the same line. It
appears to work through dynamic scoping until the day it does not.

**Pure string helpers return through `REPLY`, not stdout.** Command substitution forks,
and on a path that runs several times a second per target that cost dominates. `REPLY` is
a shared register: read it on the line immediately following the call, before anything
else can overwrite it.

**Every drawn line ends with `\033[K`.** A frame that redraws shorter content over longer
content leaves the old tail on screen otherwise.

## Style

Match the surrounding code. It is Bash 5 under `set -Eeuo pipefail`, organized into small
focused modules with data-only state files. Prefer clarity over cleverness - this is a
tool people run against their own terminals, and it should be readable by someone
debugging it at an inconvenient hour.

## Tests

New behavior needs a test. See the conventions section of
[`docs/TESTING.md`](docs/TESTING.md#writing-a-test), which lists the mistakes that have
cost time before - `assert_true` taking a command rather than a `[[ ]]` expression,
`set -e` aborting on a deliberately non-zero call, and command substitution discarding
global state.

If the behavior is only reachable by a person pressing keys, add it to
`tests/test_tui_pty.sh` rather than asserting on functions in isolation. Three real
defects once passed a fully green suite because nothing drove the actual client.

## Reporting bugs

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#reporting-a-bug) for what to
include. `keepalive doctor` output and the journal are usually enough to place a problem.

## Scope

Keep Alive Manager supports Konsole and Orca through explicit backend adapters. A new
terminal backend must provide an equally strong stable identity, live pre-send validation,
bounded discovery/delivery, persistence validation, and mock-backed integration tests.
Do not add a generic keystroke/focus-injection fallback. Open an issue before widening
the backend surface.
