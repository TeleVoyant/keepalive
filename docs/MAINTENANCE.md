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
