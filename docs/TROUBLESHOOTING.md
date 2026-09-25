# Troubleshooting

Start here:

```bash
keepalive doctor
```

It checks core dependencies, reports each terminal backend, names the runtime directory
and how it was resolved, and reports whether the control FIFO is ready. Most
problems below are visible in its output.

For daemon behavior over time:

```bash
systemctl --user status keepalive.service
journalctl --user -u keepalive.service -n 100 --no-pager
```

---

## Sessions show as `unknown` or `?`

**Cause.** The daemon cannot resolve `/proc/PID/cwd` and `/proc/PID/exe`. These are magic
symlinks, and they resolve relative to the reading process's mount namespace. A daemon
placed in its own namespace sees nothing useful.

**Fix.** Check the service unit for namespacing directives:

```bash
systemctl --user cat keepalive.service | grep -iE 'PrivateTmp|PrivateMounts|ProtectHome|RootDirectory'
```

`PrivateTmp=yes` caused exactly this and was removed in 1.0.0. `systemd/keepalive.service`
carries a comment naming the directives that must never be reintroduced. If you added
hardening of your own, remove it and restart:

```bash
systemctl --user restart keepalive.service
```

---

## `keepalive` reports the service is unreachable

Work through these in order.

**Is it running?**

```bash
systemctl --user is-active keepalive.service
systemctl --user start keepalive.socket
```

**Do the client and daemon agree on a runtime directory?** They must resolve the same
path. Compare what `doctor` reports against the daemon's own environment:

```bash
keepalive doctor | grep 'runtime directory'
systemctl --user show keepalive.service -p Environment
```

A mismatch is almost always an SSH session without `XDG_RUNTIME_DIR`. See
[Remote and non-desktop access](#remote-access-shows-nothing-or-cannot-connect).

**Is the FIFO stale?** A `kill -9` can leave the FIFO behind with nothing reading it. The
client times out rather than hanging, which is the symptom you are seeing. Restart:

```bash
systemctl --user restart keepalive.socket keepalive.service
```

**Is the machine simply loaded?** The client waits `KEEPALIVE_RESPONSE_TIMEOUT_MS`
(default 8000). Raise it for one call:

```bash
KEEPALIVE_RESPONSE_TIMEOUT_MS=20000 keepalive list
```

---

## Remote access shows nothing, or cannot connect

Keep Alive Manager manages terminal sessions on the machine where Konsole or Orca is
running. Over SSH you are attaching a client to that machine's daemon; you are not
managing your local terminal.

Two things commonly go wrong.

**`XDG_RUNTIME_DIR` is not exported.** Many SSH sessions do not run `pam_systemd`, so the
variable is missing and the client would otherwise look in the wrong place. Resolution
falls back to `/run/user/$UID` when it exists and is owned by you - confirm which source
was used:

```bash
keepalive doctor | grep 'runtime directory'
```

`(xdg)` or `(per-user)` are both fine. `(fallback)` means it is using `/tmp/keepalive-$UID`,
which the daemon will only share with a client that resolved the same way.

**The session bus is not reachable.** Discovery needs the *user* D-Bus session that
Konsole is on. If `doctor` reports zero Konsole D-Bus services while Konsole is plainly
running, point the client at the right bus:

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID/bus"
keepalive list
```

---

## Orca agents do not appear

Run:

```bash
keepalive doctor
/home/you/.local/bin/orca-ide status --json
```

The doctor must show an Orca CLI, `jq`, and a reachable runtime. On Linux, configure
`KEEPALIVE_ORCA_CLI` with the path to `orca-ide` if auto-detection misses it; do not point
it at bare `orca`, which is commonly the GNOME screen reader.

Only terminals with a non-empty Orca `agentIdentity` are listed. Ordinary shell tabs are
excluded intentionally. The terminal must also be connected, writable, and non-orphaned.

If the journal says Orca discovery did not complete after an Orca update, the CLI's JSON
contract probably changed. Existing Orca discovery rows are retained, but sends still
require live validation. Update the isolated mapping in `lib/orca.sh` and its mock test;
do not weaken schema checks or bypass identity validation.

---

## Nothing is being delivered, but the target looks healthy

**Check the target's event log first** - press `l` in target detail, or:

```bash
keepalive list --json
```

The log records refusals with reasons rather than failing silently.

**The message may be owed rather than sent.** With Konsole's default two-step delivery, a
failure between sending the text and sending the submit sequence is recorded as owed. The
next attempt completes the pending line instead of repeating it, because a blind retry
would append the message twice. This is correct behavior and resolves itself.

**The AI CLI may be debouncing input.** Some clients submit before rendering. If text
arrives but never submits, widen the gap:

```ini
[Service]
Environment=KEEPALIVE_SEND_GAP=0.4
```

If instead you want the two steps to be indivisible, opt into atomic submit - at the cost
of the debounce protection:

```ini
[Service]
Environment=KEEPALIVE_ATOMIC_SUBMIT=1
```

---

## A target went `UNAVAILABLE` and will not come back

This is deliberate and is the core safety property of the tool.

A send is permitted only when the selected backend's complete identity binding still
matches what was recorded. For Konsole that includes the session UUID, terminal PID, AI
PID/start time, and foreground ancestry. For Orca it includes runtime, handle, PTY,
terminal incarnation, worktree, execution host, pane, and agent identity. Once an
identity is lost it becomes sticky: the target is never automatically rebound to a
replacement terminal, because doing so could type into somebody else's shell.

Transient failures do not cause this - up to `KEEPALIVE_VALIDATION_STRIKES` consecutive
failures (default 5) are debounced first.

**What to do.** Delete the dead record and create a new keep-alive against the new
session. The old record stays visible until you delete it precisely so you notice.

---

## The daemon uses too much CPU

**First, confirm how many daemons are running.** This is the single most common cause of
a bad measurement:

```bash
ps -eo pid,etime,args | grep '[k]eepalive --service'
```

There should be exactly one. Orphans are usually left by ad-hoc scripts that started
`./keepalive --service &` without a cleanup trap; killing the client does not stop them,
and systemd adopts them.

**Then check the cadence.** Idle cost is dominated by discovery, which is bounded by
`KEEPALIVE_DISCOVERY_BUDGET_MS` per pass and backs off to
`KEEPALIVE_IDLE_DISCOVERY_INTERVAL` when no client is attached. If it is not backing off,
something is holding client presence open - `KEEPALIVE_CLIENT_PRESENCE_TTL` decides how
long after the last request a client still counts as attached.

See [Tuning for lower CPU](CONFIGURATION.md#tuning-for-lower-cpu) for a drop-in that
trades list freshness for idle cost.

---

## Countdown jumped after a crash

Expected, and bounded. A countdown tick marks a target dirty rather than rewriting its
checkpoint every second; the flush happens every `KEEPALIVE_CHECKPOINT_INTERVAL`
(default 30 s) and on clean shutdown.

- **Clean restart** - the countdown loses only the restart gap.
- **`kill -9`** - the countdown resumes from the last flush, so it can be up to one
  checkpoint interval stale, appearing to gain time.

Lower `KEEPALIVE_CHECKPOINT_INTERVAL` to narrow the window at the cost of more I/O.

---

## Icons render as boxes, or the layout is broken

Your terminal lacks a Nerd Font, or is not reporting a usable width. Every fallback is a
complete rendering path, not a degraded one:

```bash
keepalive --no-icons     # drop Nerd Font glyphs
keepalive --no-color     # drop ANSI color (same as NO_COLOR=1)
keepalive --ascii        # drop glyphs, color, and box-drawing characters
```

The TUI is laid out for 52 columns and up. Below that, output is truncated rather than
wrapped.

---

## Keys do nothing, or the TUI exits unexpectedly

Unrecognized escape sequences decoding as a bare Escape used to exit the client; key
decoding was rewritten byte-by-byte in 1.0.0. If you see this on 1.0.0 or later, it is a
bug worth reporting - include your `TERM`, your terminal emulator, and the exact key.

Confirm the version actually running, which is not necessarily the one in your checkout:

```bash
keepalive doctor | head -1
```

If it disagrees with `git describe`, re-run `./scripts/install.sh`.

---

## A checkpoint was quarantined

Corrupt runtime state is moved aside rather than loaded, so one bad file cannot take down
the daemon:

```bash
ls "${XDG_RUNTIME_DIR:-/run/user/$UID}/keepalive/quarantine/"
```

Each entry records why it was rejected. The affected target must be recreated. Runtime
state is intentionally not persistent across logout, so this is never a permanent loss.

---

## Reporting a bug

Please include:

```bash
keepalive doctor
keepalive --version
journalctl --user -u keepalive.service -n 100 --no-pager
ps -eo pid,etime,args | grep '[k]eepalive --service'
```

plus your terminal emulator, `TERM`, and whether you were on a local desktop session or
over SSH. For an Orca problem, also include `orca-ide --version` and the relevant journal
error, but redact prompts or worktree paths you do not want to share. Open issues at
[github.com/TeleVoyant/keepalive/issues](https://github.com/TeleVoyant/keepalive/issues).
