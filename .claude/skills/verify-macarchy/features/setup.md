# Setup lifecycle

Users review and install the curated environment, then inspect convergence and drift.
This surface is mapped but **not covered**; fresh onboarding remains a separate gate.

## Sub-features

- Plan, status and doctor for the declared core (theme, desktop, environment,
  native preferences, Homebrew packages).
- Guided selection, reviewed consent, package install and apply.
- Package review: `adopt-packages`, `install-packages`, `add-packages`.
- Journaled `apply` (theme, desktop, environment, preferences; completed stages
  roll back on failure), `recover` for an interrupted apply, and `teardown`
  (`--dry-run` supported) with ownership preservation.

## How to get to it (user POV)

- After Homebrew installation, run `macarchy setup guided` (needs a real TTY).
  Homebrew trust is guided-only; non-guided `setup apply` instead takes the
  `--approve-packages`, `--approve-preferences` and adoption digests that
  `setup plan` prints.
- Inspect with `macarchy setup plan`, `macarchy setup status` and
  `macarchy setup doctor` (`--json` supported; optional `--profile <path>` and
  `--machine-profile <path>`).
- Action-menu maintenance runs only `setup plan`, `status`, `doctor` and
  `apply --review` in a Kitty window; never guided, recover or teardown.

## Driving it with verify.py

Preconditions for a future journey: declared profile and exact known package/provider
state. Guided setup also needs an interactive terminal, explicit Homebrew trust and
manual native permission/authentication boundaries.

Report **not covered**. There is no `--journey setup`. The `lean` and
`packaged-lean` journeys incidentally run real `setup plan`/`setup apply` with a
focus-only profile, then standalone `environment apply`/`teardown`; they never run
`setup status`, `doctor`, `recover`, `teardown` or `guided`. That is lean
evidence, not setup coverage. A JSON object or exit 1
cannot establish correct setup behavior. Define source-grounded intended plan and
status first; capture reviewed actions plus actual provider/ownership results.
Never replace normal onboarding with internal state setters.

## Gotchas

The prepared guest already has Homebrew/CLT; it cannot prove first installation of
those prerequisites. No-Homebrew coverage needs its distinct baseline, not silent
substitution. Source-CLI theme proof does not qualify the shipped Homebrew binary,
guided UI, service registration, permissions, recovery or convergence.

While a unified setup journal is pending, standalone `environment apply` and
`environment teardown` (except `--dry-run`) refuse with "Recover the pending
unified operation with setup apply or setup teardown first." Setup's own stages
bypass that check.
