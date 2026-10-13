# Macarchy verification map

Read the matching page before making a feature claim. Commands run on the Mac mini;
the real product binary runs inside its disposable guest. Follow ../SKILL.md.

## Preconditions and proof

Use a fresh recorded test-base clone, `verify.py start`, then `launch`.
`doctor --run <returned-run> --session <returned-session>` must report ready.
No other driver may use that guest. Cleanup with `--shutdown` after every attempt.

The retained drive report pairs each command with stdout, stderr, exit and assertions,
plus watched-path metadata before/after. Record run/session and actual coverage.
An unavailable entry point is not covered, not silently represented by another path.
Missing prerequisites block; failures remain failures.

## Features

| Feature | Coverage |
| --- | --- |
| [Themes](theme.md) | Journey `theme`: built-ins, backgrounds, inactive status; E2E passed |
| [Keybindings](keybindings.md) | Mapped, not covered |
| [Setup](setup.md) | Mapped, not covered; no onboarding claim |
| [Action menu](menu.md) | Mapped, not covered; GUI needs separate qualification |

## Feature entry contract

Each page describes the user-visible feature and uses four H2 sections:
`Sub-features`, `How to get to it (user POV)`, `Driving it with verify.py`,
`Gotchas`. New journeys need exact source-grounded assertions and a real recorded
run before claiming coverage. Do not accept arbitrary error exits as successful proof.
