# Action menu

Control-Option-Space opens a searchable native popup with configuration, themes,
keybindings, capture and maintenance actions. This GUI surface is **not covered**.

## Sub-features

- Open, search and keyboard-navigate the menu.
- Open configuration editors and native viewers.
- Run maintenance in Kitty; review apply/update actions.

## How to get to it (user POV)

Press Control-Option-Space after setup installs the default binding, or run
`macarchy menu` in the logged-in guest desktop session. Optional `--profile` and
`--machine-profile` select declared intent.

## Driving it with verify.py

Preconditions for future coverage: a usable guest GUI session, reviewed setup,
and the providers/permissions required by the selected action (e.g. Kitty/yabai
for maintenance handoff).

Report **not covered**. There is no menu journey. Do not launch a popup over this
SSH harness and count a CLI response as visual proof. A future GUI recipe must
capture the opening action, selected row, resulting view or handoff and side effects,
using the lab's existing exact-window capture and PID-targeted input.

## Gotchas

Mouse input remains unqualified in the VM lab, and guest permissions stay manual.
Do not use global input, focus-stealing retries or desktop-capture fallback.
The theme CLI journey proves nothing about the popup; setup inspection is not
covered either. A missing provider is a blocked precondition, not menu acceptance.
