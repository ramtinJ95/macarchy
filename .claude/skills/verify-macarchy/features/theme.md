# Themes

Users list built-in themes and backgrounds, inspect active state and choose a theme.
This first journey covers browsing through the CLI and inactive status only.

## Sub-features

- `theme-list`: valid built-in IDs, appearances and display names.
- `theme-backgrounds`: each built-in's background IDs and paths.
- `theme-status`: canonical state; this journey expects inactive.
- `theme-dry-run`, `theme-activate`, `theme-next`: not driven.
- `theme-browse`: native browser; not driven.
- `theme-install`: remote theme import; not driven (network and mutation).

## How to get to it (user POV)

- Terminal: `macarchy theme list`, `macarchy theme background list <id>`,
  `macarchy theme status`.
- Choose a theme: `macarchy theme set <id> --dry-run`, then `theme set <id>`;
  cycle with `theme next` or `theme background next`.
- Native browser: `macarchy theme browse`, Command-Shift-T, or Themes in the
  Control-Option-Space action menu. These GUI entry points are not covered by the CLI.

## Driving it with verify.py

Preconditions: ../SKILL.md launch and session doctor pass; no guest
`~/.config/macarchy`. Do not remove existing configuration to satisfy this condition.

```sh
uv run --project Scripts/vm --locked python -B Scripts/vm/verify.py drive --run setup-<run-id> --session verify-<session-id> --journey theme
```

Expected: exit 0, `status: passed`, no failures, and these recorded assertions:

1. `macarchy version --json` matches the launched development binary identity.
2. `macarchy theme list` exits 0 and lists exactly the snapshot's built-in
   ID/appearance/name tuples, with no duplicates or malformed lines.
3. `macarchy theme background list <id>` exits 0 for each built-in;
   all (ID, relative path) pairs match its `Themes/*/theme.toml`.
4. `macarchy theme status --json` exits **1**, with exactly
   `{"schema_version":1,"operation":"theme_status","outcome":"inactive","active":false}`.
   Exit 1 is expected only for this precisely asserted inactive report.
5. Before/after watched metadata has no created, deleted or modified entries.

For the qualified snapshot, there are Catppuccin Mocha (4 backgrounds), Kanagawa
Wave (2), and Tokyo Night (8). Expected data is read from the actual source snapshot,
not frozen here. Proof is `drive-theme-NN/report.json`, its raw snapshots and step
outputs from `01-version.stdout` through `06-theme-status.stdout`.

## Gotchas

- Activation and even activation dry-run preflight touch provider boundaries.
  A fresh guest lacks their prerequisites, and the exact refusal is runtime-dependent.
  No arbitrary precommit failure is counted as passing activation validation.
- The state assertion intentionally covers a fresh, inactive guest, not an active one.
- List/background commands validate real packaged data; this is not GUI browsing,
  imported-theme, wallpaper, provider repaint or Homebrew installation proof.
- E2E passed on 2026-10-13 in `setup-ffe804179e62/verify-4f7e526e2357`;
  cleanup stopped that guest and retained its proof.
