# Keybindings

Users preview managed skhd bindings, apply them and inspect ownership/runtime state.
This surface is mapped but **not covered** by the verification CLI yet.

## Sub-features

- Plan effective bindings and inspect status/doctor.
- Apply, recover and teardown managed bindings.
- View the native keybinding popup and edit personal overrides.

## How to get to it (user POV)

- `macarchy keybindings plan`, `macarchy keybindings status` and
  `macarchy keybindings doctor`; review before `macarchy keybindings apply`.
- Command-K, `macarchy keybindings show --effective`, or Keybindings in the
  Control-Option-Space action menu opens the viewer.
- Configure → Keybindings in the action menu edits the override.

## Driving it with verify.py

Preconditions for a meaningful future journey: an explicitly defined profile/provider
fixture and known skhd/service state. Runtime shortcut proof additionally needs the
guest GUI and native Accessibility consent.

Report this feature **not covered**. There is no `--journey keybindings`.
Do not accept an arbitrary exit 1 or JSON object as proof of correct planning.
Before adding the journey, define exact effective bindings and typed expected
status, then capture the action and provider-visible result.

## Gotchas

A clean test-base clone has no installed skhd or Macarchy setup. Its runtime refusal
is not pinned by the source alone. Do not install packages or grant permissions to
manufacture a pass without a scoped, reviewed scenario. CLI inspection would still
not prove the viewer or that a shortcut fires.
