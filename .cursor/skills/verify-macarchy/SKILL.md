---
name: verify-macarchy
description: Verify Macarchy's current-source CLI in a disposable macOS guest on the Mac mini. Use for built-in theme/background listing and inactive status, or when extending real user-path verification. Includes launch, read-only doctor, retained evidence and cleanup. Other mapped features remain explicitly uncovered.
---

# Verify Macarchy

Build the **current working tree, including uncommitted changes**, in a disposable
`test-base` guest, then drive its real CLI. This is developer tooling, not a product
command or proof of a Homebrew installation.

- Follow `AGENTS.md` first. All commands below run **on the Mac mini** in
  `/Users/ramtin/personal/macarchy`, with
  `PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
  From the work Mac use `ssh home-macmini`, the configured home-tailnet proxy alias;
  do not use the work Tailscale connection. The client does no repository work.
- Read `features/README.md` and the matching feature page before driving.
- `theme` is qualified: listing, backgrounds and inactive status.
- `borders` passes bounded VM fixture qualification; hardware/Retina/managed replacement remain unqualified. See `features/borders.md`.
  Release builds, guest-only zsh environment apply and real theme activation passed.
  The event-driven own-outline-transaction candidate passed motion and 1/8/24
  checks: measured p95 tracking matches JankyBorders with lower helper memory.
  User accepted the bounded preview; managed replacement and host cutover remain pending.
  Aggregate setup, keybindings and GUI acceptance remain **not covered**.
- Qualified on 2026-10-13: clone, start, guest source build, doctor, theme drive,
  cleanup and evidence survival passed in `setup-ffe804179e62/verify-4f7e526e2357`.
  See its retained evidence under `artifacts/vm/runs/`.
  28 focused Python checks passed; no full Swift suite was needed for this slice.
- Pi discovers the same skill through `.pi/skills/verify-macarchy`, a symlink to
  this directory. Pi's loader was checked; Cursor runtime discovery was not.

## Launch

Prerequisites: a logged-in GUI session on the mini, `uv`, the pinned lab tooling
and stopped prepared `test-base`. The baseline has Homebrew/CLT and guest SSH,
but not Macarchy. Its initial OS preparation was manual; see `Scripts/vm/README.md`.
Missing prerequisites block the run; do not install, grant permissions or substitute
a different baseline automatically. Guest SwiftPM dependency fetching needs network.

Run these on the mini, substituting **only IDs returned by the preceding command**:

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/lab.py clone
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py start --run setup-<run-id>
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py launch --run setup-<run-id>
```

1. Clone must report `prepared_stopped_clone` and a `setup-<12 hex>` run ID.
   Never target a master or a guest another driver controls. Reuse requires the
   explicit audited restart path below, not adoption of an arbitrary running guest.
2. Start reports `running` after the existing no-TCP-listener audit. It runs the
   documented native Tart command with no clipboard/audio, records PID/start
   time/full command line, and stops its exact child if startup fails.
   **Native Tart startup may take focus on the mini.** No action repeatedly raises it.
3. Launch waits up to 300 seconds for SSH (`--wait` accepts 30–900), checks VM
   identity, account and OS build, copies a source snapshot to guest-local APFS,
   then runs `swift build --product macarchy` inside the guest (40-minute bound).
   No host mounts or build fallback. Ready means `status: ready`, a
   `verify-<12 hex>` session ID, and a recorded development `version --json`
   ending in `-dev`. Snapshot and binary SHA-256 bind the evidence to that build.
   Build failure retains `build.log`; clean up failed attempts too.

### Explicitly approved reuse

`verify.py restart --run setup-<run-id>` reboots a stopped clone previously owned
by this verifier. It requires the old exact process to be gone, archives previous
boot/shutdown evidence, and records a fresh owner/log. Default `start` still refuses
reuse. This does not reset guest state or make fresh-install claims valid. Use only
for a reviewed same-guest continuation; never delete ownership reports to restart.

## Doctor

Run before driving or whenever anything looks off:

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py doctor --run setup-<run-id> --session verify-<session-id>
```

`ready` requires matching lab pins, a running recorded test clone, no concurrent
verify operation, strict guest host-key verification, VM/account/OS identity,
the ready session's unchanged binary/version, and absent `~/.config/macarchy`.
An existing or unreadable state root blocks the fresh-state journey.
Without `--session`, the report's scope is VM readiness only, not readiness to drive.

Doctor performs no initialization, build, host-key trust or guest write. It uses a
transient host askpass helper. `--record` explicitly saves its report in session
evidence; launch establishes the run-local host key before doctor can check it.

## Drive

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py drive --run setup-<run-id> --session verify-<session-id> --journey theme
```

The fixed journey invokes the guest-built binary, not internal setters or test
endpoints: `version --json`, `theme list`, `theme background list` for every
snapshot built-in, and `theme status --json`. See `features/theme.md` for assertions.
It rechecks target, session ownership, binary identity and fresh state.

Each command uses a clean user environment with update checks and Homebrew
auto-update disabled. Before and after, checked native `find`/`stat` snapshots
compare type, mode, size, inode, mtime and ctime under these guest-home roots:
`.config`, `.cache`, `.local`, `.zshrc`, `.zprofile`, `.zshenv`, `.pi`,
`.codex`, `Library/LaunchAgents`, `Library/Application Support/Macarchy`.
Created, deleted or modified entries fail. Inspection errors, malformed output,
120-second snapshot timeout or more than 50,000 entries block the verdict.

The lock excludes simultaneous `verify.py` operations **only**. Do not use
`run-tests.py`, direct guest commands, GUI input or another driver on this guest
concurrently. A timed-out command may remain alive: clean up with `--shutdown`,
do not blindly rerun it.

Add another journey only with source-grounded expected behavior, focused tests,
a feature-map update and a real proof. Missing prerequisites are blocked, never
converted into permissive success checks. No unrestricted command passthrough.

## Evidence

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py evidence --run setup-<run-id> --session verify-<session-id>
```

Evidence survives under `artifacts/vm/runs/<run>/verify-<session>/`:

- `session.json`, `source.tar.gz`, `build.log`: exact source/build identity.
- `drive-theme-NN/report.json` and per-step stdout/stderr: commands, exits,
  elapsed time, assertions and uncovered scope.
- `watched-before.tsv`, `watched-after.tsv` and their stderr files within each
  drive directory: raw side-effect observations.
- Optional `doctor-<UTC>.json` and `cleanup.json`.
- Adjacent run records retain Tart process identity/log and supported shutdown.

Proof must include actions **and** resulting state, not just an exit or screenshot.
A theme pass proves listing and inactive status, not activation, installed release
provenance, GUI behavior or onboarding. The snapshots observe final metadata:
they are not a file-content audit or trace of transient writes. Network, browser,
process effects, paths outside these roots and physical hardware are not observed.
The update-check suppression is also source-backed; it is not a network audit.
No dry-run is currently driven or claimed safe based on its name.

Exit codes: `0` passed/ready/cleaned, `1` product/build assertion failed,
`3` blocked precondition/ownership/transport/timeout. Read the JSON status and
reason; preserve failed evidence, not only the last successful attempt.

## Cleanup

After every attempt, including failures:

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py cleanup --run setup-<run-id> --session verify-<session-id> --shutdown
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py evidence --run setup-<run-id> --session verify-<session-id>
```

Only the session's marked guest directory is removed. Supported `guest.py shutdown`
runs first; failure or timeout still leads to the owned Tart process's identity-checked
stop. No killing by name. A foreign launcher's still-running VM is blocked for its
owner to stop. If launch never returned a session, omit `--session` to stop the owned VM.
If the VM was already stopped, guest scratch remains on its disposable disk and the
report explicitly says so.

Expect cleanup `cleaned`, the owned VM stopped, and the evidence index still present
with the journey's `passed` result. Clone disks, masters and proof are never deleted;
disk pruning is a separate decision. An existing `ssh-shutdown.json` cannot be
overwritten; cleanup uses its recorded owned-process fallback.

## Helpers

- `Scripts/vm/verify.py` is executable. Its six operations are shown above;
  `python3 -B Scripts/vm/verify.py --help` lists them.
- `Scripts/vm/lab.py clone` creates the disposable baseline clone as shown above.
- `guest.py` supplies the existing SSH and shutdown boundary; `run-tests.py`
  supplies source snapshots. No parallel VM or credential subsystem.
- Pure helper checks on the mini: `python3 -B Scripts/vm/test_verify.py`.
  No VM, product execution or special files.
- Full/FIFO Swift tests are separate, guest-only via `Scripts/vm/run-tests.py`;
  never run unfiltered `swift test` on a physical Mac.

Upstream `/maintain-verification-skill` from Cursor's `pstack` plugin is the
maintenance option; it is **not installed here**. Keep this map accurate as features
change, and report uncovered entry points rather than substituting CLI evidence.
