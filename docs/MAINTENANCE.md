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
3. Never use directory basename as target identity; UUID is authoritative.
4. Never automatically attach an UNAVAILABLE record to a new UUID.
5. Never let TUI clients directly mutate target state files.
6. Never move active/log runtime data into persistent config directories.
7. Never install the daemon as root/system service.
8. Never subtract a detected long suspend/stall gap from countdowns.
9. Keep FIFO commands small; large data belongs in request directories.
10. Preserve literal messages: shell metacharacters are content, not syntax.
11. Require main-message rotations to be contiguous non-empty `001..N` files.
12. Never report a failed Konsole transport as IPC success.
13. Use monotonic time for cadence; preserve countdowns across long or backward gaps.
14. Keep qdbus and notification subprocesses bounded by explicit deadlines.
15. Treat D-Bus validation timeouts as transient, never as proof of identity loss.
16. Quarantine malformed recovery records before registering any in-memory target.
17. Clear the visible alternate screen when TUI view identity or dimensions change.
18. Size every frame from the live terminal width; never add a fixed-width frame literal.
19. Only a bare `Esc` may mean back/cancel; unrecognized escape sequences must be ignored.
20. Strip control bytes from user/filesystem text before it reaches the screen.
21. Keep `--no-icons`, `--no-color`, `NO_COLOR`, and `--ascii` complete interfaces, not degraded ones.
22. Never let a failed user action escape a TUI loop; `set -e` turns that into a client exit.
23. Only a completed D-Bus call returning a different value, or local `/proc` evidence,
    may mark a target UNAVAILABLE. Unreachable and timed-out calls are transient.
24. Return daemon-side refusal reasons to the client; never replace them with a generic string.
25. Periodic health may use the discovery snapshot; pre-send validation may not.
26. Keep event logs bounded and collapse repeated gap events.
27. Never return a value through stdout from a function that also writes to the terminal.
28. Never give `keepalive.service` a private mount namespace. `PrivateTmp`,
    `PrivateDevices`, `ProtectSystem`, `ProtectHome`, `ProtectProc`, and the
    `ProtectKernel*` family all break `/proc/PID/cwd` and `/proc/PID/exe` resolution
    for processes the daemon does not own, silently reducing every session to
    `unknown`/`?` while all tests still pass. Restrict hardening to seccomp/prctl
    directives.

## Module responsibilities

`common.sh`
: Generic data-safe helpers; avoid product logic here.

`xdg.sh`
: All path/lifetime decisions.

`classifier.sh`
: Recognition only. It must not change timers or service state.

`konsole.sh`
: Konsole transport and identity validation.

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

Prefer adding a conservative signature in `ka_classifier_init`, or use user config during experimentation:

```text
~/.config/keepalive/classifiers.tsv
```

Test exact executable/package boundaries. Avoid generic substrings such as plain `amp` without separators because they can match unrelated commands.

Add a regression case in `tests/test_classifier.sh` for both a positive and a plausible negative signature.

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

On the real KDE workstation:

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
24. Drive the full lifecycle from the CLI: `create`, `pause`, `resume`, `send`, `reset`, `mode`, `delete`, and `list --json`.
25. Confirm `systemctl --user stop keepalive.service` logs no `Failed with result`.
