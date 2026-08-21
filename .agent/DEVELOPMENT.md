# Development and Operations Memory

## Repository state at review

- Branch `master` tracked `origin/master` with no pre-existing changes.
- Current baseline HEAD is `55c8f72 fix(keepalive): propagate send failures and
  enforce canonical message rotations`, following the original implementation
  commit `1e67c2b`.
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
- all 13 test files and all 126 assertions passed after the robustness fixes;
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
validation report records a passing systemd verification. No live Plasma/Konsole
bus was available during this review.

## Test inventory

| Test | Actual focus |
|---|---|
| `test_common.sh` | Duration, safe IDs, literal metacharacters, no-newline scalar read, injectable monotonic clock. |
| `test_classifier.sh` | Claude/Gemini/Aider signatures, shell negative, ancestry basics. |
| `test_profile.sh` | Defaults, profile update, literal stored message, contiguous numbering. |
| `test_state.sh` | Mutation-free malformed CREATE/CONFIGURE rejection, create, pause/resume, transient health timeout, unavailable, replacement UUID, cleanup. |
| `test_scheduler.sh` | Main rotation, transport/validation timeout failures, enter-only preservation, timer independence, long/backward-gap preservation. |
| `test_recovery.sh` | Valid same-login recovery with unchanged durations and transient validation deferral. |
| `test_recovery_validation.sh` | Strict checkpoint validation, range/message/symlink rejection, quarantine reasons/log preservation. |
| `test_ipc.sh` | Two request IDs through one FIFO with independent responses. |
| `test_konsole_mock.sh` | Discovery/identity validation, qdbus timeout classification, notification deadline. |
| `test_tui_primitives.sh` | ASCII progress/urgency and icon-free state label. |
| `test_function_comments.sh` | Adjacent `# Role:` convention. |
| `test_install_layout.sh` | Non-root install/uninstall with mocked systemctl. |
| `test_service_integration.sh` | Cross-process daemon/client lifecycle, mocked sendText success/failure/timeout. |

Each test calls `test_env_setup`, which creates isolated temporary `HOME` and XDG
directories. Root-based CI attempts to run installation/integration behavior as
`nobody` with `runuser`.

## Important uncovered areas

Automated tests do not drive the full interactive wizard/detail/log loops, test
resize/control-sequence behavior, simulate multiple simultaneous mutating clients,
inject crashes between multi-file checkpoint/profile writes, or use real systemd
socket activation. There is no CI workflow file in the repository. See `RISKS.md`
for specific recommended regressions.

The repository explicitly leaves these to live-host qualification:

- real Konsole qdbus method names/output and `sendText` behavior;
- installed AI CLI process-tree shapes;
- Plasma graphical-session/socket lifecycle;
- KDE notification delivery;
- Nerd Font glyph cell width;
- actual suspend/resume behavior.

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
- `docs/VALIDATION.md` and root `VALIDATION.md` are the current release report.
- `.agent/` adds implementation-level handoff details and separates observed risks
  from advertised behavior.
