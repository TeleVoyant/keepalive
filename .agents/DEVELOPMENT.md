# Development and Operations Memory

## Uncommitted fix round on top of v1.1.0 — 2026-10-02

This snapshot is the final documentation/fix round on top of the `v1.1.0` release; it is
not a version bump. The aggregate suite currently passes **31 test files and 1519
assertions** (`./tests/run.sh`), and `./scripts/dev-check.sh` is the final gate before
shipping the patch.

Engineering lessons from this round:

- Bash copies a function's whole body on every call, so keep hot-path fronts tiny. Split
  the printable wrapper from the scanner (for example, `ka_sanitize_human_set` should
  fast-path ordinary values and delegate non-ASCII work to `ka_sanitize_human_scan_set`).
- A `local LC_ALL=...` assignment pays `setlocale` cost on function entry and return;
  keep locale changes out of the common ASCII front and measure them before moving them
  into a loop.
- Bash byte ordinals can be sign-extended by musl; mask byte values with `& 255` before
  comparing or converting them.
- Avoid `cmd | head` under `pipefail`: `head` can close the pipe early and turn a correct
  producer into status 141. Capture all output, then select the first line in Bash.
- When adding validation to a startup path, measure fork counts with `bash -x` and
  `strace`, not just wall time. The XDG safety/memoization pass reduced the representative
  CLI path from about 1677 ms to about 100 ms while retaining ownership/mode checks.

## Performance and update-reload pass on 2026-10-01

Scope: resource optimization of the daemon, clients, and unit, plus keeping running
keep-alives across an update (user request). The lead implemented everything in the
primary worktree; research, proofreading, test writing, and benchmarking were done by
Orca-supervised Pi workers (`pi --model openai-codex/gpt-5.6-luna --thinking max`; the
`openai/` provider has no credentials on this host). Released as 1.1.0 (tag `v1.1.0`).

Release-baseline validation at the end of this pass: `./scripts/dev-check.sh` -> 27 test
files, 1040 assertions, 0 failures (one ownership case skips unless root). The current
2026-10-02 round is 31 files/1519 assertions. Four new suites:
`test_loop_pacing.sh` (60), `test_atomic_io.sh` (108), `test_fork_free_helpers.sh` (95),
`test_update_reload.sh` (83); `test_systemd_units.sh` grew to 16. ShellCheck (container,
`koalaman/shellcheck-alpine`) showed no new findings versus the pre-change tree.

Benchmark method, reusable: run each tree's daemon under
`systemd-run --user --scope --unit=ka-bench-<name>-$RANDOM` with private HOME/XDG dirs
(runtime dir mode 0700), `KEEPALIVE_QDBUS=tests/fixtures/qdbus-mock` and the Orca mock,
alternate before/after runs of >= 60 s, and read the scope's `cpu.stat usage_usec`, the
daemon's `voluntary_ctxt_switches`, and a PATH-shim exec log. The numbers are in RISKS.md
"Resolved on 2026-10-01: daemon, client, and update resource pass". Quick live check of
the pacing on a real daemon: sample `grep voluntary_ctxt_switches /proc/<pid>/status`
a minute apart; idle with nothing monitored should grow by about two dozen.

Hard-won safety rules for agents measuring this daemon:

- An isolated `XDG_RUNTIME_DIR` must be mode 0700. Otherwise `ka_xdg_init` rejects it and
  silently falls back to `/run/user/<uid>` - the user's real runtime. Assert the resolved
  runtime path before launching anything.
- Record the pid of everything you start and signal only those. `pkill -f`/`pgrep -f`
  patterns match the invoking shell itself, and a worker killed another agent's test run
  by guessing from command lines.
- The user's own daemon may be running (systemd, `/run/user/1000/keepalive`) and actively
  delivering keep-alives; never signal it or touch its runtime.
- Bash `read -t` resumes after a trapped signal for its whole timeout; only a trap that
  exits ends it early. This is why the stop path checks `KA_SERVICE_WAITING`.
- `test_tui_pty.sh` can time out when the machine is loaded by concurrent benchmarks; it
  is documented as timing-sensitive and passes when rerun on a quiet machine.
- Mock-only harnesses missed a live bug (dropped control lines). It reproduced only with
  real socket activation plus the unit's scheduling properties. Replicate the installed
  service exactly with a transient unit before trusting a cadence change:
  `systemd-run --user --unit=ka-diag-$RANDOM --socket-property=ListenFIFO=<isolated
  runtime>/keepalive/control.fifo --socket-property=SocketMode=0600 -p Nice=10
  -p CPUSchedulingPolicy=batch -p IOSchedulingClass=idle -p TimerSlackNSec=50ms
  -p KillMode=mixed -p UMask=0077 --setenv=XDG_RUNTIME_DIR=... <tree>/keepalive --service`,
  drive it with 60+ `keepalive refresh` calls, and trace with a wrapper that sets
  `BASH_XTRACEFD` and a timestamped `PS4` before `exec bash -x keepalive --service`.
  `systemctl --user reset-failed` the transient units afterwards.

Installed on the development host on 2026-10-01 (`./scripts/install.sh`, twice: the
second time with the control-read fix). Live, same machine, 60 s cgroup samples with one
ACTIVE Orca target and no client: old daemon 7.41% CPU / 586 wakeups per minute; new
daemon 1.42% / 122. Each update reported `Reloaded 1 running keep-alive(s)` and the
countdown carried over (1422 -> 1416 s).

## Final robustness pass on 2026-10-01

At that pass the worktree had 23 test files and 683 assertions (the release baseline later
reached 27 and 1040; the current 2026-10-02 snapshot is 31 and 1519). New
invariant-focused suites
cover runtime path ownership/symlinks, checkpoint and index failure propagation, installer
and uninstaller transaction boundaries, versioned secondary prompts, client configuration
seeding, and recovery ordering. ShellCheck 0.10.0 was run in a container because it is not
installed on the host; systemd unit verification and the full Bash suite remain part of
`scripts/dev-check.sh`.

When changing lifecycle code, retain these precedence rules: response-write errors outrank
the command result; a primary command error is not masked by index publication; uninstall
file-cleanup errors outrank a simultaneous daemon-reload error; and failed uninstall
shutdown probes restore snapshotted enablement before returning the original probe status.

## Orca integration work on 2026-09-25

The current unreleased work adds an Orca backend without forking the timer/state machine.
All implementation was done in the primary worktree; Luna subagents were used only for
contract/seam/test research, per the user's instruction.

Key implementation points:

- `lib/orca.sh` owns the volatile CLI and JSON contract; `lib/transport.sh` is the generic
  dispatcher. Keep future Orca churn inside that boundary.
- Discovery accepts only connected, writable, non-orphaned terminals with a non-empty
  `agentIdentity`; normal Orca shell tabs are deliberately filtered out.
- The stored binding includes runtime, handle, PTY, incarnation, worktree, host, tab,
  leaf, and agent. It is checked live before every send.
- Schema drift fails closed. An incomplete list retains the previous Orca snapshot, and
  an unfamiliar show response is transient instead of making the target sticky.
- Konsole and Orca discovery snapshots commit independently.
- Older checkpoints without `backend` load as Konsole. Orca checkpoints whose ID and
  runtime/incarnation do not agree are rejected.
- Unit tests never inspect live Orca: shared setup exports `KEEPALIVE_ORCA_ENABLED=0`, and
  explicit Orca tests point at `tests/fixtures/orca-mock`.
- Read-only qualification against the installed `/home/niel/.local/bin/orca-ide` matched
  the adapter fields. No prompt was sent to a live user agent during development.

At the Orca-integration baseline, the suite was 389 assertions across 16 files. The
cross-distribution systemd and final hardening passes raised it to 683 assertions across
23 files. Orca coverage
lives in `test_orca_mock.sh` (50 assertions) and `test_orca_service_integration.sh` (10);
run the latter whenever service startup, backend selection, or Orca IPC semantics change.

The user intentionally renamed `.agent/` to `.agents/`. Do not recreate the singular
directory; `scripts/dev-check.sh` now checks `.agents/README.md`.

## Repository state at review

- Branch `master` tracked `origin/master` with no pre-existing changes.
- Current baseline HEAD is `ea3d6f3 feat(orca-integration)`; the **1.0.0** release remains
  tagged at `2ea6951`.
- `VALIDATION.md` and `docs/VALIDATION.md` were byte-identical.
- `.agents/` is the maintained project-memory directory; there is no repository
  `AGENTS.md`, and the former singular `.agent/` name must not be recreated.

## Coding conventions

1. Production, script, and test entry files use Bash and generally enable
   `set -Eeuo pipefail` at the entry boundary.
2. Every function must have an adjacent comment beginning `# Role:`. The lint test
   walks production and test shell files and enforces this mechanically.
3. Runtime/profile/request files are data. Never `source`, `eval`, or interpolate
   them as shell code.
4. Use UUID as identity. Never infer identity from project basename, cwd, D-Bus
   path alone, or PID alone.
5. All authoritative target mutations belong in the daemon's state/scheduler
   modules. Clients submit IPC requests.
6. Validate target identity immediately before input delivery.
7. Preserve sticky `UNAVAILABLE` and do not auto-rebind a replacement session.
8. Keep active bindings and logs in runtime storage, not persistent config.
9. Keep FIFO lines small; arbitrary messages/config stay in request files.
10. Preserve literal user message bytes as data and add tests for metacharacters.
11. Preserve independent target behavior: configuring one target must not alter
    any other active target.
12. Long scheduler gaps must preserve, not consume, countdowns.
13. Loop cadence uses monotonic uptime; a negative reading must preserve timers and reset every cadence anchor.
14. qdbus and notification helpers must remain deadline-bounded.
15. A validation timeout is transient; only definite identity loss becomes sticky UNAVAILABLE.
16. Runtime checkpoints must pass complete validation before array registration; quarantine failures with diagnostic evidence.
17. Never add a mount-namespace directive to `keepalive.service`. It silently breaks
    `/proc/PID/cwd` and `/proc/PID/exe` resolution for processes the daemon does not
    own, which is how session names and part of the classifier signature are derived.
18. Size every TUI frame from `KA_TUI_COLS`; never introduce a fixed-width frame literal.
19. Never let a user action's non-zero status escape a TUI loop. The client runs under
    `set -e`, so that exits the whole TUI. Use `ka_tui_guard_action`/`ka_tui_open_row`
    or an explicit `|| true`.
20. Only a bare `Esc` may mean back/cancel. Unrecognized escape sequences must decode to
    `UNKNOWN`, and a non-sequence byte read past an `Esc` must be queued, not dropped.
21. Strip control bytes from any user or filesystem text before rendering it.
22. Keep every presentation tier complete: powerline, colored-segment, plain-box, and
    fully 7-bit `--ascii`.
23. Prefer `REPLY`-setting helpers over command substitution in per-row render paths; a
    fork costs about 0.5-1 ms here and rows call these several times each. The same rule
    applies to the daemon loop: an early adaptive-cadence attempt put a command
    substitution in the loop condition and cost more than the polling it replaced.
24. Never return a value through stdout from a function that also prints to the terminal.
    `ka_tui_prompt_line` did, and every caller captured the prompt text along with the
    typed value, which broke all custom wizard input.
25. Keep `qdbus` working as a fallback transport. `KEEPALIVE_QDBUS` must continue to pin
    it, because that is how the suite injects its mock.
26. Interactive tests must synchronise on expected output, not sleeps, and must provide
    their own recognizable AI process. `tests/test_tui_pty.sh` was intermittently failing
    because it pointed the qdbus mock at the test's own PID and relied on an *ancestor*
    happening to be an AI client, so whether the wizard opened depended on the surrounding
    process tree. Launching one client per assertion also loaded the shared daemon enough
    to time out; related key checks now share one session.
27. After editing by string replacement, grep for each intended change. One anchor in this
    session carried a trailing space the file did not have, so the replacement silently did
    nothing and the installer's daemon-restart fix was reported as landed while it was not.
    It was caught only by exercising the behaviour on the live host.
28. Benchmark with warm binaries and interleaved ordering. A cold cache made `dbus-send`
    measure slower than `qdbus6` on the first run, which is the opposite of the truth.

The module source order in `keepalive` matters because functions share global
variables rather than namespaced objects. New modules should be sourced before
their callers.

## Primary developer commands

```bash
./scripts/dev-check.sh       # syntax, ShellCheck, version consistency, tests, systemd verify
./tests/run.sh               # all dependency-free tests
bash -n keepalive            # single-file syntax example
./keepalive --version
./keepalive --help
./keepalive --icons-test
```

For an installed live session:

```bash
keepalive doctor
keepalive status
keepalive refresh
keepalive list
systemctl --user status keepalive.socket keepalive.service
journalctl --user -u keepalive.service -f
```

Do not run installer, uninstaller, or daemon as root.

## Validation performed during this review

On 2026-08-21 with Bash 5.2.37:

- all Bash source/test files passed `bash -n`;
- all 13 test files and all 131 assertions passed after the TUI transition fix;
- entrypoint version/help/icon-test smoke checks passed;
- ShellCheck was not installed;
- the working tree was clean before `.agents/` was created.

The test suite covered a real background Bash daemon, real FIFO/filesystem IPC,
real `/proc` process loss/replacement, and a mocked qdbus executable. It validated
the `AVAILABLE -> CREATE -> ACTIVE -> SEND -> UNAVAILABLE` path and a distinct new
UUID remaining `AVAILABLE`.

An in-sandbox `systemd-analyze verify` could not initialize pass-credentials
(`SO_PASSCRED`). Re-running outside the sandbox reached unit validation and then
reported the expected missing installed executable:

```text
keepalive.service: Command /home/niel/.local/bin/keepalive is not executable:
No such file or directory
```

The repository's `scripts/dev-check.sh` handles a normal uninstalled checkout by
temporarily creating that expected symlink before verification. The committed
validation report records a passing systemd verification.

## Validation performed on 2026-08-22

This review ran **on the real KDE workstation with a live Plasma session, a live
Konsole D-Bus bus, and an installed daemon that had been running for 24 hours**.
Earlier `.agents/` notes were written without that access; do not carry forward the
old "no live bus available" caveat.

- `./scripts/dev-check.sh` reported `ALL VALIDATION CHECKS PASSED`;
- 13/13 test files and 131/131 assertions passed;
- `systemd-analyze verify` passed here, including the amended `keepalive.service`;
- ShellCheck is still not installed and remains the only skipped stage;
- `keepalive --version|--help|--icons-test|doctor|status|list` all worked live;
- live `keepalive doctor` reported all critical checks passing against `qdbus6`.

Two defects were found that mocked tests structurally cannot reach, because both
depend on the real unit sandbox and the real bus population:

1. `PrivateTmp=yes` breaking `/proc/PID/cwd` and `/proc/PID/exe`. Fixed; see
   `RISKS.md` and the mount-namespace constraint in `ARCHITECTURE.md`.
2. Discovery cost scaling with total Konsole sessions rather than monitored targets,
   measured at 57% of one core with zero keep-alives configured. Still open; see
   `RISKS.md`.

The same session then ran a full TUI overhaul. Validation for it:

- 240 render combinations (15 widths x 3 target states x 4 presentation modes) with
  ANSI stripped; no line exceeded its terminal width;
- 17 pseudo-terminal key scenarios, including every key class that previously exited
  the client, each ending in a clean exit status 0;
- the previously flaky `open wizard, cancel, quit` sequence passed 10/10 at both fast
  and human typing speeds after the Escape-pushback fix;
- suite grew from 131 to 184 assertions across the same 13 files.

A backend pass followed, driven by a fresh inspection of the non-TUI modules:

- suite grew from 184 to 213 assertions across the same 13 files;
- the wizard's custom-message path was fixed and verified end to end through a real
  pseudo-terminal against the installed binary: typing a custom message produced
  "Keep-alive created." and stored `custom keep-alive text` verbatim;
- idle daemon CPU with no keep-alives and no client attached fell from 19.20% to
  **4.77% of one core** at the same Konsole session count;
- `ka_konsole_get` fell from 12.50 ms to 4.67 ms CPU per call (warmed, interleaved A/B);
- a clean `systemctl --user stop` no longer logs `Failed with result 'exit-code'`,
  confirmed against the live journal;
- the public CLI lifecycle (create/pause/resume/delete/`--json`) is covered by the
  cross-process integration test, which previously could not reach CREATE at all.

Note for future measurement: the daemon is socket-activated, so after a session
restart it is *not* running until a client touches the socket. `keepalive status` is
enough to start it.

Useful live probes for future work on this workstation:

```bash
# Does the daemon resolve real session names, or fall back to unknown/?
keepalive list
cat -A "$XDG_RUNTIME_DIR/keepalive/index.tsv"

# Sustained daemon CPU cost since start
systemctl --user show keepalive.service -p CPUUsageNSec -p ActiveEnterTimestamp

# Reproduce discovery outside the unit to compare against what the daemon publishes
source lib/common.sh; source lib/xdg.sh; source lib/qdbus.sh
source lib/classifier.sh; source lib/konsole.sh
ka_xdg_init; ka_classifier_init; ka_qdbus_find; ka_konsole_discover

# Test a candidate unit sandbox without touching the installed unit
systemd-run --user --pipe -p PrivateTmp=yes /bin/bash -c 'readlink /proc/PID/cwd'
```

`scripts/install.sh` records whether the daemon is active and restarts it after an
update, so newly copied modules are loaded immediately. For a manual unit deployment:

```bash
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
systemctl --user disable keepalive.socket keepalive.service 2>/dev/null || true
rm -f "$unit_dir/graphical-session.target.wants/keepalive.socket" \
      "$unit_dir/graphical-session.target.wants/keepalive.service"
cp -f systemd/keepalive.service systemd/keepalive.socket "$unit_dir/"
systemctl --user daemon-reload
systemctl --user enable --now keepalive.socket
systemctl --user try-restart keepalive.service
```

## Test inventory

| Test | Actual focus |
|---|---|
| `test_common.sh` | Duration, safe IDs, literal metacharacters, no-newline scalar read, injectable monotonic clock. |
| `test_io_hardening.sh` | Read-only profile/scalar handling, FIFO/type bounds, log symlink safety, and paced stale-index publication retries (63 assertions). |
| `test_output_safety.sh` | Human/JSON sanitization, UTF-8 truncation, CLI arity/output safety, Orca bounds, and monotonic discovery deadlines (80 assertions). |
| `test_cli_status.sh` | Read-only/presence-free status JSON, one-refresh list behavior, index compatibility, detail cache, release tooling, and runner checks (74 assertions). |
| `test_classifier.sh` | Claude/Gemini/Aider signatures, shell negative, ancestry basics. |
| `test_profile.sh` | Defaults, profile update, literal stored message, contiguous numbering. |
| `test_state.sh` | Mutation-free malformed CREATE/CONFIGURE rejection, create, pause/resume, recorded refusal reasons, snapshot-backed health validation, transient-failure strike budget and recovery, unavailable, replacement UUID, cleanup. |
| `test_state_delivery.sh` | CONFIGURE crash/rollback recovery, pending-submit ownership ordering, delivery metadata persistence/bounds, legacy owner compatibility, and bounded secondary companions (110 assertions). |
| `test_scheduler.sh` | Main rotation, transport/validation timeout failures, enter-only preservation, timer independence, long/backward-gap preservation. |
| `test_recovery.sh` | Valid same-login recovery with unchanged durations and transient validation deferral. |
| `test_recovery_validation.sh` | Strict checkpoint validation, range/message/symlink rejection, quarantine reasons/log preservation. |
| `test_ipc.sh` | Two request IDs through one FIFO with independent responses. |
| `test_konsole_mock.sh` | Discovery/identity validation, qdbus timeout classification, notification deadline. |
| `test_orca_mock.sh` | Orca CLI/schema normalization, exact runtime identity, drift handling, deadlines, transport dispatch, and backend isolation. |
| `test_orca_service_integration.sh` | Real FIFO/service/client lifecycle against a mocked Orca-only runtime. |
| `test_tui_primitives.sh` | ASCII progress/urgency, icon-free state, view-aware clear and resize sequences, width-exact frame rules, truncation safety and control stripping, non-collapsing TSV split, 7-bit glyph set, status cell width, segment-bar width/fallback, and key decoding (arrows, page/home/end, unrecognized sequences, Escape pushback). |
| `test_function_comments.sh` | Adjacent `# Role:` convention, and no self-referential `local` declaration. |
| `test_tui_pty.sh` | The real client driven through `pty.fork()`: key classes that once exited it, wizard cancel from step one and from a later step, Escape pushback, and a VT-rendered screen check that no key-hint line is drawn twice. Skips cleanly without `python3`. |
| `test_install_layout.sh` | Non-root install/uninstall with mocked systemctl. |
| `test_install_lifecycle.sh` | Manager XDG agreement, migration, installed-tree upgrade, restart, rollback, and uninstall retention with a stateful systemctl mock. |
| `test_portability.sh` | Runtime-path safety/fallback, HOME/config validation, D-Bus escaping, and early informational modes. |
| `test_failure_propagation.sh` | Filesystem, FIFO, response, lock, and CLI failure propagation. |
| `test_systemd_units.sh` | Portable socket target, static-service lifecycle edges, and old-systemd compatibility guard. |
| `test_service_integration.sh` | Cross-process daemon/client lifecycle, mocked sendText success/failure/timeout with specific reasons, and the full public-CLI lifecycle: delete, create, pause/idempotent pause, resume, `--json` validated by a real parser, and a duplicate-create refusal. |

Each test calls `test_env_setup`, which creates isolated temporary `HOME` and XDG
directories. Root-based CI attempts to run installation/integration behavior as
`nobody` with `runuser`.

## Important uncovered areas

Automated tests do not validate terminal-specific wrapping and cell widths, simulate
multiple simultaneous mutating clients, inject crashes between multi-file
checkpoint/profile writes, or use real systemd socket activation. See `RISKS.md` for
specific recommended regressions.

`.github/workflows/ci.yml` runs `scripts/dev-check.sh` in a blocking root-container matrix
covering Ubuntu, Debian, Fedora, and Arch, with ShellCheck as a separate blocking job.
Those lanes are static/mock coverage; real user-manager behavior remains a VM/live-host gate.

The repository explicitly leaves these to live-host qualification:

- real Konsole qdbus method names/output and `sendText` behavior;
- installed AI CLI process-tree shapes;
- real systemd user-manager/socket lifecycle across non-KDE and headless sessions;
- KDE notification delivery;
- Nerd Font glyph cell width;
- actual suspend/resume behavior.

Three further blind spots are now known to hide real defects, because all were found
live on 2026-08-22 after the mocked suite had passed:

- **Unit sandbox effects.** Tests exercise the daemon as a plain background process,
  never under the shipped `keepalive.service` sandbox, so a hardening directive can
  silently disable `/proc` magic-symlink resolution with every test still green.
- **Cost at realistic bus population.** Tests use one mocked Konsole service with one
  session. Discovery cost scales with total sessions on the bus, so the suite cannot
  observe the polling model's real CPU behavior on a desktop with many Konsole
  windows.
- **Interactive behavior.** Key handling, navigation, and `set -e` escapes from loop
  bodies were once invisible to the suite, and three real TUI defects hid behind a fully
  green run: unrecognized escape sequences quitting the client, a swallowed key after
  `Esc`, and a cancelled wizard exiting with status 1. **This gap is now closed** by
  `test_tui_pty.sh`, which drives the real client through a pseudo-terminal, plus
  `tests/fixtures/vt-render.py`, which renders a capture into the screen a user would
  actually see. What remains uncovered is cell-width behavior in a specific font, which a
  VT emulator cannot model.

## Safe change checklist by area

### New/changed target field

Update all of:

1. declarations in `ka_state_init_arrays`;
2. `ka_state_save_target`;
3. parsing and validation in `ka_state_load_target_dir`;
4. initialization in `ka_state_create_target`;
5. configuration behavior if applicable;
6. `ka_state_delete_target` unsets;
7. `index.tsv` writer/reader columns if clients need it;
8. target-to-request/profile mapping if configurable;
9. state, recovery, and integration tests;
10. `.agents/` schemas.

Consider a checkpoint schema version before changing meanings or dropping fields;
none exists today.

### New IPC operation

1. Keep the FIFO verb as only `REQUEST <safe-id>`.
2. Put payload in data files beneath the request directory.
3. Add the uppercase operation to `ka_ipc_handle_request`.
4. Validate all payloads daemon-side before mutation.
5. Delegate behavior to state/scheduler rather than growing the IPC switch.
6. Publish index and return meaningful success/failure.
7. Add unit and cross-process coverage.
8. Update operation tables and user-facing help if exposed.

### Classifier change

Use executable/package/path boundaries and lower-case regexes. Add a positive case
and a plausible false-positive negative case. Remember discovery selects the
nearest recognized ancestor and validation later requires foreground ancestry to
remain within that AI tree.

### Scheduler/delivery change

Test all combinations of:

- automatic vs manual;
- active vs paused vs unavailable;
- message+enter vs enter-only;
- main vs secondary;
- success vs validation failure vs transport failure;
- one due timer vs both due in the same tick;
- normal elapsed, boundary elapsed, long gap, and clock anomaly;
- daemon restart with preserved checkpoints.

Never weaken pre-send validation.

### TUI/index schema change

Update both `ka_state_publish_index` and both read stages in
`ka_tui_load_index`. Test empty fields explicitly because tab is IFS whitespace in
Bash. Test narrow terminals, no colors, no icons, ASCII bars, and multi-client
refresh with selection retained by UUID.

### TUI change

The suite cannot see layout, key handling, or `set -e` escapes. Check all of:

1. Render each affected view at 52, 64, 80, 100, and 200 columns and confirm no line
   exceeds the width. Strip ANSI before measuring, or escape bytes inflate the count.
2. Render in all four presentation tiers: default, `--no-icons`, `NO_COLOR=1`, `--ascii`.
3. Exercise `ACTIVE`, `PAUSED`, and `UNAVAILABLE`, which render different blocks.
4. Confirm no user action can return non-zero into a loop body.
5. Drive the real client through a pseudo-terminal: arrows, function keys, keypad,
   `Esc`, `Esc` followed immediately by another key, wizard cancel from step 1 and
   from a later step. The client must never exit except on `q`/`Esc` at the manager.
6. Confirm no scratch file survives an interrupted client.

A minimal Python pty driver is enough: `pty.fork()`, `TIOCSWINSZ` for the size, write
keys with a settle delay, and read the master until the child exits.

### systemd unit change

`systemd-analyze verify` and the whole test suite pass regardless of sandbox
directives, so neither one can qualify this area. Always verify on a live session:

1. Confirm the directive is not mount-namespace based. When unsure, test it in
   isolation before editing the unit:
   `systemd-run --user --pipe -p <Directive> /bin/bash -c 'readlink /proc/<a foreign PID>/cwd'`
2. Deploy the unit, `daemon-reload`, and restart the service explicitly when bypassing
   the installer. The installer restarts an already-running daemon itself.
3. Confirm `keepalive list` still shows real project names, not `unknown`/`?`.
4. Confirm classification still recognizes an installed AI CLI, since
   `ka_proc_exe_basename` contributes to `ka_proc_signature`.
5. Confirm delivery still works, and that optional `notify-send` is not blocked by a
   new seccomp or address-family restriction.

## Install, update, uninstall

`./scripts/install.sh` copies source, docs, tests, and scripts to
`~/.local/share/keepalive-manager`, symlinks `~/.local/bin/keepalive`, installs the
two user units, reloads systemd, and enables/starts only `keepalive.socket`.

The installer preflights the systemd user manager, requires effective HOME/config/runtime
agreement with the caller, canonicalizes and records the complete unit root, removes
obsolete graphical-session/previous-custom-root files, enables only the socket under
`sockets.target`, and restarts an already-running daemon after copying an update.

`./scripts/uninstall.sh` removes files only after it confirms both units inactive (unless
the operator explicitly uses the recovery-only `--force`), reloads the user manager, and
deliberately retains `${XDG_CONFIG_HOME:-$HOME/.config}/keepalive`.

## Packaging

`./scripts/package.sh [OUT.zip]` deletes an existing output path, builds the allowlisted
release payload from the project parent while excluding `.git`, `.agents/`, `.github/`,
ZIPs, Python caches, and `.DS_Store`, then prints `sha256sum`. Tag releases additionally
use the export-filtered archive workflow and reject forbidden private paths.

## Documentation relationships

- `README.md` is the full operator-facing manual.
- `docs/ARCHITECTURE.md` is the intended high-level model.
- `docs/MAINTENANCE.md` holds invariants and the live workstation checklist.
- `docs/TESTING.md` describes the harness and qualification boundary.
- `docs/CONFIGURATION.md` is the complete environment-knob reference, including the
  reasoning behind each default and a drop-in recipe for applying changes to the daemon.
- `docs/TROUBLESHOOTING.md` is symptom-first user diagnosis.
- `docs/VALIDATION.md` and root `VALIDATION.md` are the current release report and are
  kept byte-identical.
- `CHANGELOG.md` is the release history; `dev-check.sh` requires a released section
  matching `KEEPALIVE_VERSION`.
- `CONTRIBUTING.md` states the conventions the automated checks enforce.
- `LICENSE` is MIT.
- `.agents/` adds implementation-level handoff details and separates observed risks
  from advertised behavior.

Version lives only in `KEEPALIVE_VERSION` in `keepalive`. Four documents repeat it and
`scripts/dev-check.sh` fails on drift, so a bump is mechanical. The release procedure is
in `docs/MAINTENANCE.md`.
