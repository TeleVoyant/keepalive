# Development and Operations Memory

## Repository state at review

- Branch `master` tracked `origin/master` with no pre-existing changes.
- Current baseline HEAD is `96b5931 perf(daemon): cut CPU with monitored targets by
  roughly five times`, the ninth commit and the basis of the **1.0.0** release.
- `VALIDATION.md` and `docs/VALIDATION.md` were byte-identical.
- `.agents/` and `.codex/` existed as empty read-only environment directories;
  there was no repository `AGENTS.md`.
- `.agent/` was created in response to the request for durable project memory.

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
./scripts/dev-check.sh       # syntax, optional ShellCheck, tests, systemd verify
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
- the working tree was clean before `.agent/` was created.

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
Earlier `.agent/` notes were written without that access; do not carry forward the
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

Remember that `scripts/install.sh` does not restart a running daemon. After changing
unit files or sourced modules, deploy and restart explicitly:

```bash
cp -f systemd/keepalive.service ~/.config/systemd/user/keepalive.service
systemctl --user daemon-reload
systemctl --user restart keepalive.service
```

## Test inventory

| Test | Actual focus |
|---|---|
| `test_common.sh` | Duration, safe IDs, literal metacharacters, no-newline scalar read, injectable monotonic clock. |
| `test_classifier.sh` | Claude/Gemini/Aider signatures, shell negative, ancestry basics. |
| `test_profile.sh` | Defaults, profile update, literal stored message, contiguous numbering. |
| `test_state.sh` | Mutation-free malformed CREATE/CONFIGURE rejection, create, pause/resume, recorded refusal reasons, snapshot-backed health validation, transient-failure strike budget and recovery, unavailable, replacement UUID, cleanup. |
| `test_scheduler.sh` | Main rotation, transport/validation timeout failures, enter-only preservation, timer independence, long/backward-gap preservation. |
| `test_recovery.sh` | Valid same-login recovery with unchanged durations and transient validation deferral. |
| `test_recovery_validation.sh` | Strict checkpoint validation, range/message/symlink rejection, quarantine reasons/log preservation. |
| `test_ipc.sh` | Two request IDs through one FIFO with independent responses. |
| `test_konsole_mock.sh` | Discovery/identity validation, qdbus timeout classification, notification deadline. |
| `test_tui_primitives.sh` | ASCII progress/urgency, icon-free state, view-aware clear and resize sequences, width-exact frame rules, truncation safety and control stripping, non-collapsing TSV split, 7-bit glyph set, status cell width, segment-bar width/fallback, and key decoding (arrows, page/home/end, unrecognized sequences, Escape pushback). |
| `test_function_comments.sh` | Adjacent `# Role:` convention, and no self-referential `local` declaration. |
| `test_tui_pty.sh` | The real client driven through `pty.fork()`: key classes that once exited it, wizard cancel from step one and from a later step, Escape pushback, and a VT-rendered screen check that no key-hint line is drawn twice. Skips cleanly without `python3`. |
| `test_install_layout.sh` | Non-root install/uninstall with mocked systemctl. |
| `test_service_integration.sh` | Cross-process daemon/client lifecycle, mocked sendText success/failure/timeout with specific reasons, and the full public-CLI lifecycle: delete, create, pause/idempotent pause, resume, `--json` validated by a real parser, and a duplicate-create refusal. |

Each test calls `test_env_setup`, which creates isolated temporary `HOME` and XDG
directories. Root-based CI attempts to run installation/integration behavior as
`nobody` with `runuser`.

## Important uncovered areas

Automated tests do not validate terminal-specific wrapping and cell widths, simulate
multiple simultaneous mutating clients, inject crashes between multi-file
checkpoint/profile writes, or use real systemd socket activation. See `RISKS.md` for
specific recommended regressions.

`.github/workflows/ci.yml` runs `scripts/dev-check.sh` as the blocking job, with
ShellCheck as a separate advisory job.

The repository explicitly leaves these to live-host qualification:

- real Konsole qdbus method names/output and `sendText` behavior;
- installed AI CLI process-tree shapes;
- Plasma graphical-session/socket lifecycle;
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
10. `.agent/` schemas.

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
2. Deploy the unit, `daemon-reload`, and restart the service explicitly; the
   installer will not restart a running daemon for you.
3. Confirm `keepalive list` still shows real project names, not `unknown`/`?`.
4. Confirm classification still recognizes an installed AI CLI, since
   `ka_proc_exe_basename` contributes to `ka_proc_signature`.
5. Confirm delivery still works, and that optional `notify-send` is not blocked by a
   new seccomp or address-family restriction.

## Install, update, uninstall

`./scripts/install.sh` copies source, docs, tests, and scripts to
`~/.local/share/keepalive-manager`, symlinks `~/.local/bin/keepalive`, installs the
two user units, reloads systemd, and enables/starts only `keepalive.socket`.

The current installer does not explicitly restart an already running daemon after
copying an update. A maintenance update should therefore include:

```bash
systemctl --user restart keepalive.service
```

when a daemon is active and immediate use of new sourced code is desired.

`./scripts/uninstall.sh` disables/stops both units, removes installed source,
symlink, and units, reloads the user manager, and deliberately retains
`${XDG_CONFIG_HOME:-$HOME/.config}/keepalive`.

## Packaging

`./scripts/package.sh [OUT.zip]` deletes an existing output path, zips the project
from its parent directory while excluding `.git`, ZIPs, Python caches, and
`.DS_Store`, then prints `sha256sum`. The new `.agent/` directory is not excluded
and will be included unless the packaging policy is changed.

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
- `.agent/` adds implementation-level handoff details and separates observed risks
  from advertised behavior.

Version lives only in `KEEPALIVE_VERSION` in `keepalive`. Four documents repeat it and
`scripts/dev-check.sh` fails on drift, so a bump is mechanical. The release procedure is
in `docs/MAINTENANCE.md`.
