# Keep Alive Manager: Agent Memory

This directory is a durable, evidence-based handoff for future work on this
repository.

It records the repository understanding produced from a full source, test, documentation,
service-unit, and history review, most recently refreshed after the final portability and
transaction-safety review and the performance and update-reload pass on 2026-10-01.

It does **not** contain hidden model instructions, private chain-of-thought, secrets,
or transient platform state. It contains the useful project context another
maintainer or coding agent needs in order to continue safely.

## Snapshot

- Repository: `TeleVoyant/keepalive`
- Branch: `master`
- Reviewed baseline commit: the `v1.1.0` release commit (previous release `v1.0.0` at
  `2ea6951`, Orca integration at `ea3d6f3`)
- Release: **1.1.0**, released 2026-10-01 and tagged `v1.1.0`. Licensed MIT.
- Product version: `1.1.0`
- Implementation: Bash 5+, Linux `/proc`, Konsole D-Bus and Orca CLI adapters,
  `systemd --user`
- Contents of 1.1.0 since `ea3d6f3`, in order: the cross-distribution systemd portability and
  transaction-safety hardening pass, then the **2026-10-01 performance and update-reload
  pass** - deadline-paced daemon loop, presence-driven publication and discovery,
  fork-free hot paths, single-`jq` Orca parsing, low-priority unit scheduling, graceful
  stop, installer reload verification, and TUI self-reload after an update. Measured
  results are in RISKS.md; method and safety rules in DEVELOPMENT.md.
- Tests: 27 files, 1040 assertions, all passing (`./scripts/dev-check.sh`).
- Installed on the development host from the release tree (2026-10-01); the live
  daemon runs 1.1.0.
- Orca's volatile CLI/JSON contract stays isolated in `lib/orca.sh`, with generic
  dispatch in `lib/transport.sh` and a mock-backed daemon integration test.
- `.agent/` was renamed to `.agents/` by the user; do not recreate the singular
  directory.

## Memory map

- [PROJECT.md](PROJECT.md): purpose, product behavior, source map, commands,
  dependencies, paths, and configuration knobs.
- [ARCHITECTURE.md](ARCHITECTURE.md): process model, discovery, identity,
  state schemas, IPC, scheduler, recovery, and end-to-end flows.
- [DEVELOPMENT.md](DEVELOPMENT.md): conventions, testing, validation evidence,
  installation, release flow, and change checklists.
- [RISKS.md](RISKS.md): reproduced defects, implementation caveats, known
  qualification boundaries, and recommended test additions. Read the dated
  "Resolved on" sections before assuming a listed problem is still present.

The user-facing documentation is now the better starting point for most questions, and
these notes deliberately do not duplicate it:

- [`../docs/CONFIGURATION.md`](../docs/CONFIGURATION.md): every environment knob with its
  default and the reasoning for it.
- [`../docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md): symptom-first diagnosis.
- [`../docs/TESTING.md`](../docs/TESTING.md): what each of the 1040 assertions covers and
  the conventions for adding one.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md): the conventions the automated checks
  enforce.

## Fast orientation

Keep Alive Manager supports long-running terminal AI clients in Konsole and agents
launched inside Orca. A single per-user daemon discovers both backends, maintains
independent countdowns, and delivers through Konsole's D-Bus `sendText` or Orca's atomic
terminal-send command. Any number of short-lived CLI/TUI clients communicate with that
daemon through a private request-directory protocol signaled by a small FIFO line.

The most important invariant is that the daemon is the only authoritative writer
of monitored target state. A send is permitted only after the selected backend's entire
persisted identity still matches live state. Lost identities become sticky
`UNAVAILABLE`; they are never rebound automatically to a replacement terminal. An
unfamiliar Orca schema is transient and fails closed rather than being mistaken for
identity loss.

## Source-of-truth order

When memory and code differ, trust them in this order:

1. Current executable code and systemd units.
2. Current tests.
3. The repository's `docs/` and `README.md` contracts.
4. These `.agents/` notes.

After meaningful changes, update this directory or delete stale claims. Always
rerun `./scripts/dev-check.sh` (or at minimum `./tests/run.sh` plus Bash syntax
checks) before treating a change as complete.

`dev-check.sh` now also fails when the version in `keepalive` disagrees with any of the
four documents that repeat it or with `CHANGELOG.md`, so a release bump is mechanical.
The full release procedure is in
[`../docs/MAINTENANCE.md`](../docs/MAINTENANCE.md#cutting-a-release).
