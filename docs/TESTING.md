# Testing

The test suite is plain Bash and deliberately requires no Bats/Python runtime.

## Run everything

```bash
./scripts/dev-check.sh
```

## Run unit/integration-mock tests

```bash
./tests/run.sh
```

Each `test_*.sh` receives an isolated temporary `HOME`, `XDG_CONFIG_HOME`, and `XDG_RUNTIME_DIR`; tests do not modify the real user's profile.

## Current coverage

- `test_common.sh`: duration helpers, scalar safety, shell-metacharacter literal handling.
- `test_classifier.sh`: recognized wrapper signatures, negative matching, ancestry basics.
- `test_profile.sh`: default profile, updates, literal messages.
- `test_state.sh`: create/pause/resume/unavailable/delete, independent log cleanup, new-UUID no-reattach behavior.
- `test_service_integration.sh`: real background daemon + FIFO + public client processes with mocked qdbus; covers create/send/loss/replacement UUID end-to-end.
- `test_scheduler.sh`: main rotation, Enter-only queue preservation, secondary/main independence, suspend-gap preservation.
- `test_recovery.sh`: same-login daemon restart countdown recovery.
- `test_install_layout.sh`: non-root install/uninstall layout with mocked systemctl.
- `test_ipc.sh`: multiple request IDs through one FIFO and responses.
- `test_konsole_mock.sh`: mocked Konsole service/path/UUID/PID discovery and strict validation.
- `test_tui_primitives.sh`: ASCII/no-icon progress/status output.
- `test_function_comments.sh`: every function has a `# Role:` maintenance comment.

## What automated tests cannot prove here

A headless/container build cannot prove behavior of the real workstation's:

- Plasma graphical-session lifecycle;
- live user D-Bus;
- actual Konsole `sendText` behavior;
- real AI process trees for every installed AI CLI version;
- desktop notification server;
- Nerd Font cell rendering;
- suspend/resume behavior of that specific kernel/session stack.

Use the live checklist in `docs/MAINTENANCE.md` before treating a new release as workstation-qualified.
