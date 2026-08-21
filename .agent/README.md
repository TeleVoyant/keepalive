# Keep Alive Manager: Agent Memory

This directory is a durable, evidence-based handoff for future work on this
repository. It records the repository understanding produced from a full source,
test, documentation, service-unit, and history review on 2026-08-21.

It does **not** contain hidden model instructions, private chain-of-thought, secrets,
or transient platform state. It contains the useful project context another
maintainer or coding agent needs in order to continue safely.

## Snapshot

- Repository: `TeleVoyant/keepalive`
- Branch: `master`
- Reviewed baseline commit: `55c8f72` (`fix(keepalive): propagate send failures and enforce canonical message rotations`)
- Product version: `0.1.0`
- Implementation: Bash 5+, Linux `/proc`, Konsole D-Bus, `systemd --user`
- History at review time: one implementation commit
- Current worktree hardening: monotonic/injectable scheduling with backward-clock
  preservation; bounded qdbus/notification subprocesses with transient timeout
  semantics; strict checkpoint recovery with diagnostic quarantine.
- Working tree before this directory was added: clean and aligned with
  `origin/master`

## Memory map

- [PROJECT.md](PROJECT.md): purpose, product behavior, source map, commands,
  dependencies, paths, and configuration knobs.
- [ARCHITECTURE.md](ARCHITECTURE.md): process model, discovery, identity,
  state schemas, IPC, scheduler, recovery, and end-to-end flows.
- [DEVELOPMENT.md](DEVELOPMENT.md): conventions, testing, validation evidence,
  installation, release flow, and change checklists.
- [RISKS.md](RISKS.md): reproduced defects, implementation caveats, known
  qualification boundaries, and recommended test additions.

## Fast orientation

Keep Alive Manager is a Konsole-only manager for long-running terminal AI clients.
A single per-user daemon discovers supported AI processes, maintains independent
countdowns, and injects a configured message plus carriage return (or carriage
return alone) with Konsole's `org.kde.konsole.Session.sendText`. Any number of
short-lived CLI/TUI clients communicate with that daemon through a private
request-directory protocol signaled by a small FIFO line.

The most important invariant is that the daemon is the only authoritative writer
of monitored target state. A send is permitted only after the original Konsole
session UUID, terminal PID, AI PID/start time, and current foreground ancestry all
still match. Lost identities become sticky `UNAVAILABLE`; they are never rebound
automatically to a replacement terminal.

## Source-of-truth order

When memory and code differ, trust them in this order:

1. Current executable code and systemd units.
2. Current tests.
3. The repository's `docs/` and `README.md` contracts.
4. These `.agent/` notes.

After meaningful changes, update this directory or delete stale claims. Always
rerun `./scripts/dev-check.sh` (or at minimum `./tests/run.sh` plus Bash syntax
checks) before treating a change as complete.
