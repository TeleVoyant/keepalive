# Validation Report

Date: 2026-08-23
Version: 0.1.0

## Automated result

The release candidate passed:

```text
Bash syntax:                 PASS
Function-role comment lint:  PASS
Test files:                  14 / 14 PASS
Assertions:                  300 / 300 PASS
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
- An injectable monotonic source is parsed safely; backward readings preserve countdowns and reset cadence rather than freezing work.
- Hung qdbus calls terminate at their configured deadline, return IPC failure, and do not turn a valid target sticky UNAVAILABLE.
- Hung optional notification helpers terminate at their configured deadline without failing keep-alive work.
- Same-login daemon recovery preserves main/secondary remaining time.
- Recovery accepts fully valid checkpoints but quarantines malformed fields, out-of-range timers, UUID/path mismatches, missing files, broken rotations, and symlinked records/messages.
- Quarantine records retain a precise rejection reason and preserve matching event logs without following rejected symlinks.
- AI process loss becomes sticky UNAVAILABLE.
- An old unavailable Avela UUID and a new same-directory Avela UUID coexist as separate UNAVAILABLE/AVAILABLE records; no auto-reattach occurs.
- Delete removes only keep-alive runtime state/history.
- `--no-icons`/ASCII timer primitives remain semantically readable.
- First TUI draw, renderer transitions, and terminal resize clear the visible screen while same-view refresh avoids repeated full erases.
- Every frame is sized from live terminal width: verified across 15 widths from 52 to 200 columns, three target states, and four presentation modes with no line exceeding the terminal.
- Truncation never overruns: non-positive derived widths yield nothing instead of printing the untruncated string.
- Control bytes in messages, directories, and process labels are stripped before reaching the screen.
- Index rows decode faithfully, including empty columns that Bash `read` would otherwise collapse.
- `--ascii` renders a fully 7-bit interface, frame glyphs included, not only ASCII progress bars.
- Colored segment headers degrade to plain boxed headers when color is unavailable or the bar would not fit.
- Only a bare `Esc` cancels: arrows, function keys, keypad keys, and bracketed-paste markers are ignored rather than exiting the client.
- A key typed immediately after `Esc` is preserved rather than swallowed.
- A cancelled wizard or a rejected daemon action returns to the previous screen instead of terminating the client.
- Client scratch directories and index sort files do not survive an interrupted TUI.
- Wizard input is returned out of band, so custom messages and intervals are stored verbatim instead of being contaminated by prompt text and cursor escapes.
- Wizard steps render the shared colored segment header with step progress, degrading to the boxed header without color and to a 7-bit frame under `--ascii`.
- Daemon refusals reach the client with their specific reason, on both the CLI and the TUI.
- A D-Bus call that could not be made is transient and debounced; only a completed call returning a different value, or local `/proc` evidence, marks a target UNAVAILABLE.
- Periodic health validation reuses the discovery snapshot and issues no D-Bus call for an already-discovered target, while pre-send validation stays live.
- The public CLI drives the whole lifecycle: create, pause, idempotent pause, resume, delete, and `list --json` validated by a real JSON parser.
- Event logs are trimmed to a retention budget and repeated scheduler-gap events collapse to one entry per episode.
- Every drawn TUI line erases its own tail, so a frame that changes height cannot leave the previous line's text beside the new one.
- One discovery pass is time-bounded; a truncated pass retains the previous snapshot instead of publishing a partial one.
- A message delivered without its submit is completed on the next attempt rather than re-sent, and the event log records that state.
- Main rotations and message lengths are bounded, and all control characters are stripped from untrusted labels.
- The predictable /tmp runtime fallback is refused when it is a symlink or not owned by this user.
- Message-directory replacement commits through a staged swap that rolls back on failure, with abandoned staging directories swept at startup.
- Re-running the installer restarts an already active daemon so clients never talk to stale sourced code.
- A pseudo-terminal test drives the real client, and a small VT emulator renders the capture so stale-tail defects are visible to the suite.
- Detail-view `e` sends a single Enter and returns the target to MESSAGE+ENTER without consuming a queued message; `E` pins ENTER ONLY.
- The secondary prompt fires automatically once per arming and re-arms only on reconfiguration, while manual secondary sends stay available.
- Checkpoints written before `secondary_done` existed still load and default to not-yet-sent.
- No `local` declaration reads a name it defines in the same statement, which bash expands before creating any of them.
- A client outside a PAM session still finds the daemon: the runtime base falls back to `/run/user/$UID` before `/tmp`, and `doctor` names the rule that chose it.
- A control FIFO left behind by a killed daemon times out the client instead of blocking it forever.
- A failing periodic daemon task warns and continues rather than aborting the daemon into a systemd restart loop.
- A vanished runtime directory ends the daemon cleanly, and lock contention exits successfully instead of being retried.
- A timer event is consumed and checkpointed before delivery, so a crash between sending and checkpointing cannot repeat it.
- An unreachable daemon reports a reason rather than an empty one.
- User installer places source, symlink, and systemd units correctly and enables the socket entrypoint.
- `keepalive.socket` and `keepalive.service` pass `systemd-analyze verify`.

## Remaining live-host qualification gate

This report was produced **on the target KDE workstation**, against a live Plasma session, a live Konsole user D-Bus with 11 services and 16 sessions, and an installed daemon. Live discovery, `keepalive doctor`, `keepalive list`, unit verification, and pseudo-terminal TUI runs were all exercised there.

The following still require deliberate runtime qualification rather than being covered by automated claims:

1. live Konsole `sendText` injection into a real AI client (delivery is still mock-covered only);
2. process-tree shapes of every installed AI CLI beyond Claude;
3. systemd user socket activation under `graphical-session.target` from a cold login;
4. KDE notification delivery;
5. Nerd Font glyph cell widths in the user's configured Konsole font, including the powerline caps and wedges;
6. real laptop suspend/resume lifecycle.

The complete live checklist is in `docs/MAINTENANCE.md`.

## Confidence statement

The implementation has high confidence for the designed Bash state machine, IPC, data safety, timer semantics, UUID/no-reattach behavior, installer layout, and daemon/client lifecycle exercised by the included tests. The project intentionally labels live KDE workstation qualification as a separate final gate rather than treating mocked D-Bus validation as proof of the physical host environment.
