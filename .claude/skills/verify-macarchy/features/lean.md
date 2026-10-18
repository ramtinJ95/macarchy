# Opt-in managed lean focus

Borders remains the default. Lean is an opt-in managed provider, not a new
physical/display/Spaces/real-app/soak or visual-parity qualification.

## Sub-features

- Exact-owned persistent launchd helper; standalone preview still caps at 300 s.
- Stable launch path survives upgrades; stale owned processes are restartable.
- Canonical palette acknowledgement without a helper restart.
- No periodic runtime writes: startup/palette publication plus PID/start liveness,
  not a heartbeat or hung-runloop guarantee. Refusals stay stopped; logs are bounded.
- Stopped-service diagnosis and repair, disable, re-enable and teardown.
- Managed login preflight waits up to 60 s for this user's completed on-console
  session, using a 0.5 s timer with 0.1 s tolerance and no retry-time writes.
  Preview remains immediate. Deterministic startup refusals exit 78 and remain
  stopped; launchd KeepAlive retries crashes only.
- During pointer swaps, palette read/decode errors retain the last complete
  palette and retry the next 0.25 s poll (0.05 s tolerance). Log the first failure
  once per consecutive run; success resets the budget. Eight consecutive failures
  terminate managed mode with 78 and an explicit final diagnostic. Publication
  failures are not retried. No idle publication or heartbeat is introduced.
- Theme reconciliation starts a stopped exact-owned job once and reports the
  repair plus palette acknowledgement. It does not create an absent registration.
  Any start while the job is loaded (`kickstart`/`kickstart -k`) has a 35 s bound
  to accommodate launchd's configured 30 s throttle after a recent exit; bootstrap
  and `launchctl print` stay at 5 s and the `pgrep` inspection at 2 s.
- Managed Borders handoff/rollback and unmanaged refusal have injected lifecycle
  tests; this journey does not install Borders or claim native handoff evidence.

## How to get to it (user POV)

Set the profile's `[focus_ring] provider = "lean"` and review `setup plan`,
then `setup apply`. The matching `macarchy-focus-ring` must be beside `macarchy`.
Use `environment doctor` for applied state. Set `provider = "borders"` to return
to Borders, or `"disabled"` to remove managed focus. No automatic host switch.

## Driving it with verify.py

Run the normal fresh-clone/start/launch flow, establish the console login (see
../SKILL.md, Drive), rerun doctor, then:

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py drive \
  --run setup-<run> --session verify-<session> --journey lean
```

Requires the guest's console owned by `omarchy` (checked only as `stat -f %Su
/dev/console`; unlocking is not checked), absent incumbent processes and
`homebrew.mxcl.borders`/`sh.brew.borders` registrations, an absent managed plist, an
absent guest `~/.config/macarchy` and an absent journey scratch directory. Each
journey needs its own fresh clone: `start` refuses a clone it already started. Never
grant permissions, install tools or automate login without separate approval. All
product mutations remain guest-only.

The fixed recipe builds the matching helper from the same source snapshot, uses
a focus-only profile, runs real setup plan/apply, changes Catppuccin to Tokyo Night,
and checks the same PID/start identity and canonical generation/accent. It sends
SIGTERM to the exact owned job, checks that crash-only KeepAlive leaves it stopped,
then requires explicit reconcile repair and a new acknowledged process identity. It boots
out only the owned job, requires doctor failure, repairs through environment apply,
and checks the same owned PID/start after 305 s. Read-only proc_pid_rusage counters
must show zero logical-write/disk-write deltas, with unchanged runtime-file
identity/metadata/content. It then disables/re-enables
and tears down through the product CLI.

Last passed on 2026-10-18 at `0a499fff` (0.13.1-dev) in
`setup-6454f824d1d8/verify-3eabc8ffc48e/drive-lean-01`, run from the mini's
`macarchy-scratch/package-lean-focus-helper` worktree (as was packaged-lean).
Stopped-job reconcile completed in 22.647 s (an earlier 5 s bound had failed; hence
35 s). Over 306.060914 s: zero logical-write bytes, zero disk-write bytes and zero
runtime-file replacements. Unrelated Borders ownership cases have injected tests.
The report and per-command logs retain runtime identity and resulting state.

The `packaged-lean` journey additionally builds all release products and runs the
release archive smoke/rejection gates in that fresh guest. It copies the validated
archive's `bin` and `share` into `<VERSION>_1` and `<VERSION>_2` under one
exclusive, marked `/opt/homebrew/Cellar/macarchy` root (its `.verify-owner` marker
and inode are recorded first) and links all three executables under
`/opt/homebrew/bin`, matching the formula's `prefix.install "bin", "share"` shape.
No brew invocation, receipt, tap edit, trust or permission grant. Targets must be
absent, including dangling links; cleanup checks the recorded Cellar inode/marker
and exact owned links.

After initial setup/live palette checks it switches only those links, applies
through the new packaged CLI, and requires a new PID/start and second Cellar
executable with unchanged palette and plist. `ProgramArguments[0]` must remain
`/opt/homebrew/bin/macarchy-focus-ring`. The existing repair, idle-I/O, disable,
re-enable and teardown proof then runs against that second copy. Finally it
requires no helper/job/plist, removes only owned package fixtures, and reports
cleanup failures explicitly. Always finish with the normal cleanup/shutdown;
if transport fails, leave uncertain fixtures on the stopped disposable disk.

Last passed on 2026-10-18 at `0a499fff`:
`setup-2418039dc241/verify-999f065fd0bd/drive-packaged-lean-01`. Version 0.13.1,
`0.13.1_1` → `0.13.1_2` with a new PID and stable `ProgramArguments[0]`; 306.056548
s with zero logical/disk write bytes and no runtime-file replacement. Package
fixtures and session removed, guest stopped. This simulates an upgrade using the
same artifact in two paths; it does not prove Homebrew commands, receipts, package
migration or old/new code compatibility. Archive identity, source snapshot and build
logs are retained in the report/evidence; the archive itself is removed with guest
scratch.

## Gotchas

The minimal guest lacks default consumers. Disabling the only provider and
teardown both remove owned lean successfully, then return exit 1/blocked when
the existing default-consumer reconciliation runs. The journey accepts only
the exact expected consumer failures and positive lean removal result; it
separately requires no helper, job, plist, runtime receipt, ownership or journal.
This is **not full teardown convergence**. The provider-independent behavior
predates this slice: base `a947ef7`, `EnvironmentApply.swift:261–306` (now
`:264–309`), restores the default adapter set whenever environment ownership is absent.

Since `be7df829`, standalone `environment apply`/`teardown` refuse while a unified
setup journal is pending. The journey's repair, disable, re-enable and teardown
steps run after `setup apply`, so they also prove that a completed setup apply
leaves no pending journal.

No pixel claim follows from palette acknowledgement. Actual Homebrew install
provenance and physical rollout remain separately coordinated.
Sealed theme generation directories are mode0555; cleanup now grants owner write
permission recursively without following symlinks, only after the existing
session marker and non-symlink checks, then removes that exact guest directory.
BSD chmod requires the absolute path immediately after the mode (a post-mode
`--` is a filename); rm retains its option terminator. Failure stderr is bounded
and retained. Native cleanup/shutdown evidence is stored beside the drive report.
