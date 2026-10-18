# Action menu

Control-Option-Space opens a searchable native popup with configuration, themes,
keybindings, capture and maintenance actions. This GUI surface is **not covered**.

## Sub-features

- Open, search and keyboard-navigate the menu.
- Open configuration editors and native viewers. Appearance and Capture rows
  start detached `macarchy` viewers (`theme browse`, `keybindings show
  --effective`, `capture screenshot|annotate|ocr`).
- Configure rows open Neovim in a new Kitty window. Saving can apply: the
  profile editor may apply keybindings, and desktop/bar editors may apply
  their configuration. Treat these as mutating paths.
- Run maintenance in Kitty (`setup plan|status|doctor`, `setup apply --review`,
  `update check`, `update --review`).

## How to get to it (user POV)

Press Control-Option-Space after setup installs the default binding, or run
`macarchy menu` in the logged-in guest desktop session. Optional `--profile` and
`--machine-profile` select declared intent for editors and setup maintenance; the
two update actions drop them.

The `macarchy-menu` product is the SketchyBar Apple-menu helper, not this popup.
Never use it as the action menu's entry point.

## Driving it with verify.py

Preconditions for future coverage: a usable guest GUI session, reviewed setup,
and the providers/permissions required by the selected action: every Configure
and Maintenance row needs `/Applications/kitty.app`; Configure rows also need
`/opt/homebrew/bin/nvim`; only Maintenance adds a yabai floating rule
(`/opt/homebrew/bin/yabai`).

Report **not covered**. There is no menu journey. Do not launch a popup over this
SSH harness and count a CLI response as visual proof. A future GUI recipe must
capture the opening action, selected row, resulting view or handoff and side effects,
using the lab's existing exact-window capture and PID-targeted input.

## Gotchas

Mouse input remains unqualified in the VM lab, and guest permissions stay manual.
Do not use global input, focus-stealing retries or desktop-capture fallback.
The theme CLI journey proves nothing about the popup; setup inspection is not
covered either. A missing provider is a blocked precondition, not menu acceptance.
