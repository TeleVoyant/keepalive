# Validation Report

Date: 2026-08-21
Version: 0.1.0

## Automated result

The release candidate passed:

```text
Bash syntax:                 PASS
Function-role comment lint:  PASS
Dependency-free test files:  12 / 12 PASS
Assertions:                  90 / 90 PASS
systemd-analyze verify:      PASS
Installer layout simulation: PASS (non-root + mocked systemctl)
Daemon/client integration:   PASS (real Bash processes/FIFO + mocked qdbus)
ShellCheck:                   NOT RUN (not installed in build environment)
```

Run the same aggregate command with:

```bash
./scripts/dev-check.sh
```

## High-value scenarios validated

- Literal message strings containing shell metacharacters remain data and are never executed.
- Scalar files without trailing newlines are read correctly.
- Profile updates do not require sourcing configuration.
- Main-message requests must be contiguous non-empty `001..N` rotations; malformed CREATE/CONFIGURE data is rejected before target/profile mutation.
- Claude/Gemini/Aider wrapper signatures are recognized while an ordinary shell remains unclassified.
- Mocked Konsole discovery records the expected `shellSessionId`, service, path, and PID.
- Strict identity validation rejects a different session UUID.
- Multiple client request IDs can traverse the same FIFO and receive independent responses.
- A real background service process can be controlled by a separate public `keepalive` client process.
- CREATE crosses the real FIFO/request-directory boundary and produces ACTIVE target state.
- Manual MAIN sends cross daemon IPC and invoke mocked Konsole `sendText`.
- Main and secondary transport failures return failure after logging/checkpointing while preserving the defined timer and rotation semantics.
- A mocked qdbus transport failure crosses the real daemon/FIFO boundary as `ERROR`, not a false success.
- MESSAGE+ENTER advances rotation; ENTER_ONLY does not consume the queued message.
- Secondary sends preserve the main remaining timer.
- Large scheduler gaps preserve both timers.
- Same-login daemon recovery preserves main/secondary remaining time.
- AI process loss becomes sticky UNAVAILABLE.
- An old unavailable Avela UUID and a new same-directory Avela UUID coexist as separate UNAVAILABLE/AVAILABLE records; no auto-reattach occurs.
- Delete removes only keep-alive runtime state/history.
- `--no-icons`/ASCII timer primitives remain semantically readable.
- User installer places source, symlink, and systemd units correctly and enables the socket entrypoint.
- `keepalive.socket` and `keepalive.service` pass `systemd-analyze verify`.

## Remaining live-host qualification gate

This environment does not expose the target workstation's real Plasma graphical session or Konsole user D-Bus. The following therefore remain runtime qualification items rather than automated claims:

1. actual `qdbus6` output on Parrot/KDE and live Konsole `sendText` injection;
2. actual Claude Code/Codex/Kimi process trees installed on the workstation;
3. systemd user socket activation under the workstation's `graphical-session.target`;
4. KDE notification delivery;
5. Nerd Font glyph widths in the user's configured Konsole font;
6. real laptop suspend/resume lifecycle.

The complete live checklist is in `docs/MAINTENANCE.md`.

## Confidence statement

The implementation has high confidence for the designed Bash state machine, IPC, data safety, timer semantics, UUID/no-reattach behavior, installer layout, and daemon/client lifecycle exercised by the included tests. The project intentionally labels live KDE workstation qualification as a separate final gate rather than treating mocked D-Bus validation as proof of the physical host environment.
