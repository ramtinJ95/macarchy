# Setup lifecycle

Users review and install the curated environment, then inspect convergence and drift.
This surface is mapped but **not covered**; fresh onboarding remains a separate gate.

## Sub-features

- Plan, status and doctor for the declared core.
- Guided selection, reviewed consent, package install and apply.
- Recovery and teardown with ownership preservation.

## How to get to it (user POV)

- After Homebrew installation, run `macarchy setup guided`.
- Inspect with `macarchy setup plan`, `macarchy setup status` and
  `macarchy setup doctor` (`--json` supported; optional `--profile <path>`).
- Action-menu maintenance opens the same operations in a Kitty window.

## Driving it with verify.py

Preconditions for a future journey: declared profile and exact known package/provider
state. Guided setup also needs an interactive terminal, explicit Homebrew trust and
manual native permission/authentication boundaries.

Report **not covered**. There is no `--journey setup`. A JSON object or exit 1
cannot establish correct setup behavior. Define source-grounded intended plan and
status first; capture reviewed actions plus actual provider/ownership results.
Never replace normal onboarding with internal state setters.

## Gotchas

The prepared guest already has Homebrew/CLT; it cannot prove first installation of
those prerequisites. No-Homebrew coverage needs its distinct baseline, not silent
substitution. Source-CLI theme proof does not qualify the shipped Homebrew binary,
guided UI, service registration, permissions, recovery or convergence.
