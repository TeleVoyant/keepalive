# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Keep Alive Manager is a pure-Bash (5.0+) per-user `systemd --user` daemon plus attachable TUI/CLI
that periodically sends keep-alive prompts to long-running terminal AI clients in Konsole (D-Bus
`sendText`) and Orca (`orca-ide terminal send`). Linux only; it reads `/proc` directly.

## Commands

```bash
./scripts/dev-check.sh            # the gate: syntax, ShellCheck, version consistency, tests, systemd verify
                                  # must end with "ALL VALIDATION CHECKS PASSED"; CI runs exactly this
KEEPALIVE_SKIP_SHELLCHECK=1 ./scripts/dev-check.sh   # what the CI distro containers run
./tests/run.sh                    # whole suite (aggregates per-file assertion summaries)
bash tests/test_scheduler.sh      # one file — the normal way to iterate
find . -path ./.git -prune -o -type f \( -name '*.sh' -o -name keepalive \) -print0 | xargs -0 shellcheck -x
                                  # zero findings required; CI pins ShellCheck v0.10.0
./scripts/bump-version.sh X.Y.Z   # release bump; full procedure in docs/MAINTENANCE.md#cutting-a-release
./scripts/install.sh              # copies to ~/.local/share/keepalive-manager, never with sudo
```

There is no single-assertion filter; run the file. Python 3 (PTY fixtures) is optional and that
test file skips cleanly without it. Orca tests run on the built-in awk reader when `jq` is absent;
`tests/test_orca_parity.sh` runs them under every available reader. The live daemon on a dev host runs from
the installed copy, not this checkout, so changes only reach it after `./scripts/install.sh`.

## Architecture

One executable, `keepalive`, plays three roles: TUI client (no args), maintenance CLI
(`list`, `create`, `configure`, …), and the hidden daemon (`--service`). It `source`s every
`lib/` module in a fixed order. **Modules share globals rather than namespaces, so source order
matters**; a new module must be sourced before its callers.

**The daemon is the only writer of target state.** Clients never touch state files. An operation
is two-part: the client creates a private request directory under
`<runtime>/keepalive/requests/<id>/`, then writes just `REQUEST <id>` to the systemd `ListenFIFO`
(`%t/keepalive/control.fifo`). The daemon answers in a response directory. Payloads never go
through the FIFO. Clients read the published `index.tsv` (21 positional columns; 1–15 are stable,
and new columns are only ever appended). `status --json` is the exception: a read-only snapshot
reader that never activates or contacts the daemon.

Module layering (details in `docs/MAINTENANCE.md#module-responsibilities`):
- `konsole.sh` / `orca.sh` are backend adapters. **Every Orca CLI command, JSON path, schema gate
  and error mapping stays inside `orca.sh`**, because Orca's interface is volatile. It normalizes
  everything to a `terminal-v1` contract. Orca's JSON is read with `jq` when installed, otherwise
  with `orca.awk` (POSIX awk). **The jq programs in `orca.sh` and `orca.awk` are one contract**:
  change both together and keep their output byte-identical.
- One odd Orca row must never fail a whole discovery pass: understood-but-undeliverable rows
  (no PTY, foreign host, shared incarnation) are skipped and counted; only an unknown envelope or
  a JSON type Orca never emits fails closed (`schema:<gate>`).
- `transport.sh` is the backend-neutral validate/deliver dispatcher. `scheduler.sh`, `state.sh`
  and recovery depend on it and never on a provider's commands.
- `state.sh` holds authoritative mutations and atomic checkpoints. `scheduler.sh` handles
  countdowns, event priority and message rotation. `ipc.sh` handles the protocol only and
  delegates to state/scheduler. `service.sh` runs the event loop only.
- `classifier.sh` recognizes AI processes from position-aware `/proc` signatures and does nothing
  else.
- `xdg.sh` owns every path and lifetime decision. Runtime state and logs live under the runtime dir
  (gone at logout). Only the single default profile persists, under `$XDG_CONFIG_HOME/keepalive/`.
- `lib/tui/` is presentation only.

**Identity and safety model.** A target is identified by a backend-qualified ID: the Konsole
session UUID, or `orca-<runtimeId>-<incarnationId>`. It is never identified by a directory name or
a bare PID. The full stored binding is re-validated live immediately before every send.
`AVAILABLE → ACTIVE ⇄ PAUSED → UNAVAILABLE`. UNAVAILABLE is sticky and is never automatically
rebound to a replacement terminal. Only a *completed* backend response showing a different
identity, or `/proc` evidence, may mark a target UNAVAILABLE. Timeouts, an unreachable backend and
an unfamiliar schema are transient and fail closed.

**Time model.** Countdowns run on integer monotonic seconds from `/proc/uptime`. A gap larger than
`KEEPALIVE_SUSPEND_GAP`, or a backward reading, *preserves* countdowns instead of consuming them.
The loop does not poll: it blocks in the FIFO read until the earliest due task (at most 5 s). The
one-second tick runs only while some target is ACTIVE, because the tick's elapsed time is the
suspend detector. Discovery backs off on client presence (never on target count). Health
validation runs on its own cadence and may use the discovery snapshot; pre-send validation never
does. Countdown decrements are flushed lazily; state transitions and deliveries checkpoint
immediately. Recovery quarantines any malformed checkpoint before it registers a target.

## Conventions enforced by tests/lint

- Every function has an adjacent `# Role:` comment saying why it exists
  (`tests/test_function_comments.sh`).
- No self-referential `local` (`local dir=$1 file="$dir/x"` is wrong: Bash expands all the words
  first). This is also tested.
- Hot-path string helpers return through the shared `REPLY` register, not stdout, to avoid
  forks. Read `REPLY` on the very next line. Paired helpers exist, such as `ka_proc_starttime`
  (prints) and `ka_proc_starttime_set` (sets `REPLY`); use the `_set` form in loops.
- Never apply ShellCheck's SC2004 advice. Subscripts are associative-array keys, so `a[k]` reads
  the literal key `"k"`. Read the reasons in `.shellcheckrc` before disabling another code.
- Under `set -Eeuo pipefail` the TUI exits on any unguarded non-zero action. Guard actions with
  `ka_tui_guard_action` or `|| true`. Every drawn line ends with `\033[K`. Size frames from
  `KA_TUI_COLS` and never from a fixed width.
- Read numeric knobs through `ka_tunable` and never interpolate one into `(( ))`. Never
  `source`/`eval` profile, request, message or runtime data.
- Never give `systemd/keepalive.service` a mount-namespace directive (`PrivateTmp`, `Protect*`,
  …). It silently breaks `/proc/PID/cwd` and `/proc/PID/exe` resolution while all tests still
  pass. Never call bare `orca` on Linux (that is the GNOME screen reader); resolve `orca-ide`.

The full list of safety invariants (52) is in `docs/MAINTENANCE.md`. It also has the checklists for
adding an IPC operation or a target field. Read it before touching the scheduler, state or
backends.

## Tests

Source `tests/testlib.sh`, call `test_env_setup`, assert, then `test_finish`. `test_env_setup`
isolates `HOME`/`XDG_*` in a temp dir and sets `KEEPALIVE_ORCA_ENABLED=0`, so a test never
reaches live Orca agents. Orca tests opt back in with `KEEPALIVE_ORCA_ENABLED=1` and
`KEEPALIVE_ORCA_CLI=tests/fixtures/orca-mock`; Konsole tests use `tests/fixtures/qdbus-mock` via
`KEEPALIVE_QDBUS`. Gotchas: `assert_true` takes a command, not a
`[[ ]]` expression. `$(...)` discards globals and `REPLY`. Any test that starts a daemon needs an
EXIT trap that kills it. Behavior only reachable through key presses belongs in
`tests/test_tui_pty.sh`, which synchronizes on output (`@text` waits) and never on sleeps. The
mocks cannot prove live contracts: backend, TUI, scheduler and unit changes also need the live
checklist in `docs/MAINTENANCE.md`.

## Docs, versioning, and agent notes

- The version lives only in `KEEPALIVE_VERSION` in `keepalive`. `README.md`, `VALIDATION.md`,
  `docs/VALIDATION.md` and `.agents/README.md` repeat it, and `CHANGELOG.md` needs a dated
  `## [X.Y.Z] - YYYY-MM-DD` section. `dev-check.sh` fails on any drift. `VALIDATION.md` and
  `docs/VALIDATION.md` are kept byte-identical.
- `.agents/` (plural; never recreate `.agent/`) holds durable handoff notes: `PROJECT.md`,
  `ARCHITECTURE.md`, `DEVELOPMENT.md`, and `RISKS.md`, which records reproduced defects and
  measured results. Refresh these after meaningful changes. When the notes and code disagree,
  trust code > tests > `docs/`/`README.md` > `.agents/`.
- `.agents/` and `.github/` are `export-ignore`d and excluded from release archives.
