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
- Managed Borders handoff/rollback and unmanaged refusal have injected lifecycle
  tests; this journey does not install Borders or claim native handoff evidence.

## How to get to it (user POV)

Set the profile's `[focus_ring] provider = "lean"` and review `setup plan`,
then `setup apply`. The matching `macarchy-focus-ring` must be beside `macarchy`.
Use `environment doctor` for applied state. Set `provider = "borders"` to return
to Borders, or `"disabled"` to remove managed focus. No automatic host switch.

## Driving it with verify.py

Run the normal fresh-clone/start/launch flow, then:

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py drive \
  --run setup-<run> --session verify-<session> --journey lean
```

Requires the guest's unlocked `omarchy` console, absent incumbent processes/jobs,
and an absent managed plist. Never grant permissions, install tools or automate
login without separate approval. All product mutations remain guest-only.

The fixed recipe builds the matching helper from the same source snapshot, uses
a focus-only profile, runs real setup plan/apply, changes Catppuccin to Tokyo Night,
and checks the same PID/start identity and canonical generation/accent. It boots
out only the owned job, requires doctor failure, repairs through environment apply,
and checks the same owned PID/start after 305 s. Read-only proc_pid_rusage counters
must show zero logical-write/disk-write deltas, with unchanged runtime-file
identity/metadata/content. It then disables/re-enables
and tears down through the product CLI.

Passed on 2026-10-16 in `setup-e5e7d3b12d4a`, `verify-71037ac092da/drive-lean-01`.
Over 306.076546 s: zero logical-write bytes, zero disk-write bytes and zero
runtime-file replacements. Stable-upgrade and unrelated Borders ownership cases
are covered by injected tests, not a native Homebrew-upgrade claim.
The report and per-command logs retain runtime identity and resulting state.

## Gotchas

The minimal guest lacks default consumers. Disabling the only provider and
teardown both remove owned lean successfully, then return exit 1/blocked when
the existing default-consumer reconciliation runs. The journey accepts only
the exact expected consumer failures and positive lean removal result; it
separately requires no helper, job, plist, runtime receipt, ownership or journal.
This is **not full teardown convergence**. The provider-independent behavior
predates this slice: base `a947ef7`, `EnvironmentApply.swift:261–306`, restores
the default adapter set whenever environment ownership is absent.

No pixel claim follows from palette acknowledgement. Release archives and
Homebrew install provenance belong to the packaging slice.
Sealed theme generation directories are mode0555; cleanup now grants owner write
permission recursively without following symlinks, only after the existing
session marker and non-symlink checks, then removes that exact guest directory.
BSD chmod requires the absolute path immediately after the mode (a post-mode
`--` is a filename); rm retains its option terminator. Failure stderr is bounded
and retained. Native cleanup/shutdown evidence is stored beside the drive report.
