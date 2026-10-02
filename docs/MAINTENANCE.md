# Maintenance Guide

## Function documentation convention

Every Bash function must have a nearby comment beginning with:

```bash
# Role: ...
function_name() {
```

The comment should state **why the function exists and what responsibility it owns**, not merely restate its name.

`tests/test_function_comments.sh` enforces this convention.

## Safety invariants contributors must preserve

Do not merge changes that weaken these rules:

1. Never source/eval profile, request, message, or runtime target data.
2. Never send text before `ka_scheduler_validate_before_send` succeeds.
3. Never use directory basename as target identity; the backend-qualified ID is authoritative.
4. Never automatically attach an UNAVAILABLE record to a new backend identity.
5. Never let TUI clients directly mutate target state files.
6. Never move active/log runtime data into persistent config directories.
7. Never install the daemon as root/system service.
8. Never subtract a detected long suspend/stall gap from countdowns.
9. Keep FIFO commands small; large data belongs in request directories.
10. Preserve literal messages: shell metacharacters are content, not syntax.
11. Require main-message rotations to be contiguous non-empty `001..N` files.
12. Never report a failed terminal transport as IPC success.
13. Use monotonic time for cadence; preserve countdowns across long or backward gaps.
14. Keep qdbus, Orca CLI, and notification subprocesses bounded by explicit deadlines.
15. Treat backend timeouts and unfamiliar provider schemas as transient, never as proof of identity loss.
16. Quarantine malformed recovery records before registering any in-memory target.
17. Clear the visible alternate screen when TUI view identity or dimensions change.
18. Size every frame from the live terminal width; never add a fixed-width frame literal.
19. Only a bare `Esc` may mean back/cancel; unrecognized escape sequences must be ignored.
20. Strip control bytes from user/filesystem text before it reaches the screen.
21. Keep `--no-icons`, `--no-color`, `NO_COLOR`, and `--ascii` complete interfaces, not degraded ones.
22. Never let a failed user action escape a TUI loop; `set -e` turns that into a client exit.
23. Only a completed backend call returning a different identity, or local `/proc`
    evidence, may mark a target UNAVAILABLE. Unreachable, timed-out, and structurally
    unfamiliar responses are transient.
24. Return daemon-side refusal reasons to the client; never replace them with a generic string.
25. Periodic health may use the discovery snapshot; pre-send validation may not.
26. Keep event logs bounded and collapse repeated gap events.
27. Never return a value through stdout from a function that also writes to the terminal.
28. Every drawn TUI line must erase its own tail; never add escapes to a `printf` whose
    output is consumed as data.
29. Bound discovery and publish only complete per-backend snapshots; one failed backend
    must not erase another backend's rows.
30. Complete a partially delivered message; never re-send it.
31. Verify the runtime base before use when it is not an XDG runtime directory.
32. The secondary prompt fires once per arming; only reconfiguration re-arms it.
33. Never write `local a=$1 b="$a..."`: bash expands every assignment word before creating
    any of them. `tests/test_function_comments.sh` enforces this.
34. Resolve the runtime base by precedence; never assume `XDG_RUNTIME_DIR` is set.
35. Never open the control FIFO write-only.
36. Periodic daemon work warns and continues; only a vanished runtime directory stops the loop.
37. Read numeric tuning knobs through `ka_tunable`; never interpolate one into `(( ))`.
38. Keep the control read able to tell an idle timeout from a broken descriptor.
39. Never mark a target UNAVAILABLE for a configuration fault; unavailable records cannot be reconfigured.
40. Never give `keepalive.service` a private mount namespace. `PrivateTmp`,
    `PrivateDevices`, `ProtectSystem`, `ProtectHome`, `ProtectProc`, and the
    `ProtectKernel*` family all break `/proc/PID/cwd` and `/proc/PID/exe` resolution
    for processes the daemon does not own, silently reducing every session to
    `unknown`/`?` while all tests still pass. Restrict hardening to seccomp/prctl
    directives. Process-level scheduling directives (`Nice=`, `CPUSchedulingPolicy=batch`,
    `IOSchedulingClass=idle`, `TimerSlackNSec=`) create no namespace and are in use; never
    use `CPUSchedulingPolicy=idle`, which can starve a due send, and never rely on cgroup
    caps (`CPUWeight=`, `Memory*=`, `TasksMax=`), which need controller delegation that
    user managers do not guarantee.
41. Keep Orca commands, JSON paths, and error-code mappings inside `orca.sh`; the generic
    state machine and scheduler consume only the normalized transport contract.
42. Never invoke bare `orca` on Linux; resolve `orca-ide` explicitly so the GNOME screen
    reader cannot be mistaken for the terminal CLI.
43. Plan the scheduler tick only while a target is ACTIVE, and then every second: the
    tick's elapsed time is the suspend detector, so a slower tick would preserve every
    countdown as a false gap and a tick across a planned long sleep would log one.
44. Never publish screen escapes into `clients.seen`; it is data the daemon parses as
    epoch seconds, and a decorated stamp silently disables attached-client cadence.
45. A stop signal never ends the daemon mid-work. It exits at once only while idle in the
    control read, and otherwise at the top of the next loop iteration, so a delivery in
    flight completes; `KillMode=mixed` keeps systemd from killing that delivery's helper.
    Never restore `trap 'exit ...' TERM`: an update's restart then cut sends in half.
46. A timed-out control read may still hold the first bytes of a request (Bash keeps
    partial input on timeout). `ka_ipc_service_read` must complete such a line, never
    discard it; timer slack makes the race common enough to drop about 5% of requests.

## Module responsibilities

`common.sh`
: Generic data-safe helpers; avoid product logic here.

`xdg.sh`
: All path/lifetime decisions.

`classifier.sh`
: Recognition only. It must not change timers or service state.

`konsole.sh`
: Konsole transport and identity validation.

`orca.sh`
: Volatile Orca CLI/JSON adapter, normalized identity contract, and atomic delivery.

`transport.sh`
: Backend-neutral validation/delivery dispatch. Scheduler/recovery code depends on this,
  not on a provider command surface.

`state.sh`
: Authoritative target/discovery state mutations and atomic snapshots.

`scheduler.sh`
: Time decrementing, event priority, message rotation, delivery semantics.

`ipc.sh`
: Request/response protocol. It delegates product operations to state/scheduler modules.

`service.sh`
: Lifecycle and event-loop orchestration; keep business logic out of the loop.

`tui/*`
: Presentation/client behavior only. TUI must never become authoritative state.

## Extending AI recognition

Prefer adding a conservative, position-aware signature in `ka_classifier_init`, or use user config during experimentation:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/keepalive/classifiers.tsv
```

Built-ins inspect only command-identifying positions: `comm`, resolved executable path/basename, `argv[0]` path/basename, and the first script/module/package identifier recognized for supported launchers. They deliberately exclude shell `-c` payloads, environment assignments, editor/pager/grep/git arguments, and option values. User `classifiers.tsv` rows retain the legacy full lower-case `comm exe cmdline` matching behavior, so user regexes must be treated as trusted, potentially broad rules. Test exact executable/package boundaries. Avoid generic substrings such as plain `amp` without separators because they can match unrelated commands.

Add a regression case in `tests/test_classifier.sh` for both a positive and a plausible negative signature, including one wrapper form and one argument-only false positive.

## Adding a daemon command

1. Add a short uppercase operation in `ka_ipc_handle_request`.
2. Put any non-trivial payload in the request directory.
3. Validate all fields before state mutation.
4. Call a state/scheduler function rather than implementing business logic inside IPC.
5. Publish index after mutation.
6. Add unit tests.
7. Document CLI/TUI semantics if operator-visible.

## Changing runtime state

If a new target field is added:

1. add its associative array in `ka_state_init_arrays`;
2. save it in `ka_state_save_target`;
3. parse/validate it in `ka_state_load_target_dir`;
4. initialize it in `ka_state_create_target`;
5. unset it in `ka_state_delete_target`;
6. expose it in `index.tsv` only if clients require it;
7. add recovery/state tests.
8. decide whether older checkpoints remain valid or must be quarantined, and test both paths.

## Useful commands

```bash
# Full local validation
./scripts/dev-check.sh

# Tests only
./tests/run.sh

# Syntax only
find . -type f \( -name '*.sh' -o -name keepalive \) -print0 |
  xargs -0 -n1 bash -n

# User service diagnostics after install
systemctl --user status keepalive.socket keepalive.service
journalctl --user -u keepalive.service -f

# Force current discovery
keepalive refresh
keepalive list

# Inspect profile
keepalive profile

# Environment/integration checks
keepalive doctor
```

## Live integration test checklist

On a real systemd user session (and on KDE as well when validating Konsole):

1. Start two Claude Code sessions in separate Konsole tabs and one Codex/Kimi if available.
2. `keepalive` should list each once, sorted Claude → Codex → Kimi → other.
3. Configure two independent keep-alives with different intervals/messages.
4. Close TUI; verify service keeps counting/sending.
5. Reopen TUI from another terminal; verify state is unchanged.
6. Open a second TUI simultaneously; pause in one and confirm the other reflects it.
7. Toggle ENTER_ONLY and verify only carriage return is sent and main message index is unchanged.
8. Let secondary fire; verify main remaining time is preserved.
9. Stop/restart `keepalive.service`; verify same UUID state/timers recover.
10. Exit one AI client; verify sticky UNAVAILABLE plus target-lost notification.
11. Start new AI in same directory; verify a separate AVAILABLE UUID appears.
12. Delete old unavailable record; verify new terminal remains unaffected.
13. Suspend laptop with known remaining time; resume and verify countdown preserved.
14. Test `--no-icons`, `NO_COLOR=1`, and `--ascii` from another terminal emulator.
15. Temporarily block the session bus/helper and confirm timeout failures do not make a valid target sticky UNAVAILABLE.
16. Corrupt a disposable runtime checkpoint and confirm it moves to `quarantine/` with a reason rather than loading.
17. Navigate manager → detail → logs/wizard → back and resize each view; confirm no previous-view cells remain.
18. Confirm `keepalive list` shows real project directory names rather than `unknown`/`?`; a regression here means the service unit gained a mount-namespace directive.
19. Press Right/Left arrow, a function key, and a keypad key in the manager; the client must ignore them and stay open.
20. Open the wizard and cancel with `Esc` from step 1 and from a later step; the manager must return, not exit.
21. Resize the terminal from very wide down to 52 columns in each view; no line may wrap and no border may overrun.
22. Compare the default, `--no-icons`, `NO_COLOR=1`, and `--ascii` renderings of the manager, target detail, and every wizard step.
23. Create a keep-alive through the wizard using a **custom** message and a custom interval; both must be accepted and stored verbatim.
24. Drive the full lifecycle from the CLI: `create`, `configure`, `pause`, `resume`, `send`, `reset`, `mode`, `delete`, and `list --json`.
25. Confirm `systemctl --user stop keepalive.service` logs no `Failed with result`.
26. Press `r` repeatedly in target detail and add a message in the wizard; no key-hint line may appear twice.
27. Re-run the installer while the daemon is active with an ACTIVE and a PAUSED target and
    the manager TUI open; it must restart the service, print `Reloaded 2 running
    keep-alive(s)`, keep both countdowns, and the TUI must restart itself on the same row.
28. Press `e` in target detail: one Enter must be sent and delivery must return to MESSAGE+ENTER.
29. Press `E`: delivery must stay ENTER ONLY until `e` or a reconfigure changes it.
30. Enable the secondary prompt and let it fire; it must not fire a second time until reconfigured.
31. Run `env -u XDG_RUNTIME_DIR keepalive status` and `keepalive doctor`; both must find the running daemon and name the runtime source.
32. Kill the daemon with SIGKILL, leaving its FIFO behind, then run a client; it must time out rather than hang.
33. Start the daemon with a deliberately invalid knob such as `KEEPALIVE_HEALTH_INTERVAL=2s`; it must warn once and keep running on the default.
34. Remove a target's message files while it is active; the target must stay usable and the log must say to reconfigure it.
35. Leave one active target with no client attached for a minute; discovery must back off to `KEEPALIVE_IDLE_DISCOVERY_INTERVAL`, and attaching a client must return it to the fast cadence.
36. Restart the daemon cleanly with a known remaining time; the countdown must lose only the restart gap, not a whole checkpoint interval.
37. `kill -9` the daemon; systemd must restart it, the countdown must resume at most `KEEPALIVE_CHECKPOINT_INTERVAL` stale, and `quarantine/` must stay empty.
38. In Orca, launch a disposable agent and confirm it appears exactly once with backend
    `orca`; an ordinary Orca shell terminal must not appear.
39. Create an Orca keep-alive and manually send a harmless prompt; verify text plus Enter
    arrives once and the event log records success.
40. Restart Orca or replace the disposable terminal; the old record must become sticky
    UNAVAILABLE and the replacement must appear separately.
41. Temporarily make the Orca runtime unreachable; one send must fail with an Orca-specific
    reason while the target remains ACTIVE until the transient strike budget is exhausted.
42. Run Konsole and Orca together, then break one backend's discovery; rows from the other
    backend must continue to refresh.
43. In a GNOME, other-desktop, or headless login where `graphical-session.target` is
    inactive, install and confirm `keepalive.socket` is enabled through `sockets.target`.
44. Stop `keepalive.service` and confirm the next client request reactivates it; then stop
    `keepalive.socket` and confirm the service stops and the FIFO is removed.
45. Upgrade an installation that still has
    `graphical-session.target.wants/keepalive.socket`; confirm the obsolete link is gone
    and the `sockets.target.wants` link is present.
46. With nothing monitored and no client attached, sample the daemon for a minute
    (`grep ctxt /proc/<pid>/status` before and after); voluntary context switches must
    grow by roughly a dozen, not hundreds. Attach the TUI and confirm `clients.seen`
    holds bare digits and the AVAILABLE rows refresh within a few seconds.

## Cutting a release

Version lives in exactly one place, `KEEPALIVE_VERSION` in `keepalive`. Four documents
repeat it, and `scripts/dev-check.sh` fails if any of them drifts, so the bump is
mechanical rather than a thing to remember. Run the helper from the repository root:

```bash
./scripts/bump-version.sh X.Y.Z
```

It updates the executable and four document version lines, moves an existing
`[Unreleased]` section (or creates a dated section), and adds the matching changelog link
reference. Running it again for the same version is idempotent.

1. Run `./scripts/bump-version.sh X.Y.Z` and review the generated changelog section.
2. Run `./scripts/dev-check.sh`; it must end with `ALL VALIDATION CHECKS PASSED`.
3. Work through the live integration checklist above in a non-KDE systemd user session,
   on a real KDE/Konsole workstation for that backend, and with a disposable Orca agent.
   Neither mocks nor container unit parsing can prove a live provider/user-manager contract.
4. Refresh `VALIDATION.md` and `docs/VALIDATION.md` with the observed assertion count
   and the live evidence.
5. Commit, then tag: `git tag -a vX.Y.Z -m 'Keep Alive Manager X.Y.Z'` and
   `git push origin master --follow-tags`.
6. The `v*.*.*` push starts `.github/workflows/release.yml`, which validates the tag,
   builds the archive/checksum, extracts the changelog section, and creates or updates
   the GitHub Release.
