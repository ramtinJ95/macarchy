# Opt-in managed lean focus

Borders remains the default. Lean is an opt-in managed provider, not a new
physical/display/Spaces/real-app/soak or visual-parity qualification.

## Sub-features

- Exact-owned persistent launchd helper; standalone preview still caps at 300 s.
- Canonical palette acknowledgement without a helper restart.
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
and checks main-runloop acknowledgement after 305 s. It then disables/re-enables
and tears down through the product CLI.

Passed on 2026-10-16 in `setup-129c04fc3969`, `verify-506b7529726e/drive-lean-02`,
product source snapshot `0341926a5cb69a0127a728b7ed9d09c96b2d5d740ea254259caef4e7abe0c596`.
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
Supported guest shutdown passed and owned Tart exited. Session-directory removal
returned exit 1; remaining scratch stays on the stopped disposable disk. Host
evidence survives. Do not broaden deletion or permissions to hide that limitation.
