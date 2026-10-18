# Keybindings

Users preview managed skhd bindings, apply them and inspect ownership/runtime state.
This surface is mapped but **not covered** by the verification CLI yet.

## Sub-features

- Plan effective bindings; inspect `status`, `doctor` and `list`.
- Apply managed bindings (`--dry-run`, `--adopt <digest>` from a reviewed plan).
  An interrupted transaction is recovered inside `apply`; there is no
  `keybindings recover` or `teardown`. Teardown runs through `setup teardown`,
  `setup recover` or top-level `macarchy teardown`.
- View the native keybinding popup and edit personal overrides.
- Through setup, keybindings belong to the desktop component and are planned
  only when the desktop provider is `yabaiSkhd`.

## How to get to it (user POV)

- `macarchy keybindings plan`, `status`, `list` and `doctor`; review before
  `macarchy keybindings apply`. `status` exits 1 unless the state is `converged`.
  Without `--effective`, `list`, `doctor` and `show` read `~/.config/skhd/skhdrc`
  and `~/.config/macarchy/keybindings.toml` rather than managed state.
- Command-K, `macarchy keybindings show --effective`, or Appearance → Keybindings
  in the Control-Option-Space action menu opens the viewer.
- Configure → "Configure keybindings" in the action menu edits the override
  (`overrides/keybindings.skhdrc` by default, set by `keybindings.override`).

## Driving it with verify.py

Preconditions for a meaningful future journey: an explicitly defined profile/provider
fixture and known skhd/service state. Runtime shortcut proof additionally needs the
guest GUI and native Accessibility consent.

Report this feature **not covered**. There is no `--journey keybindings`, and the
`lean`/`borders` profiles set `[desktop] provider = "disabled"`, so no journey
plans or applies skhd. Read-only candidates for a future journey are `plan`,
`status`, `list --effective`, `doctor --effective` and `apply --dry-run`; their
transitive inspection code has not been audited for writes.
Do not accept an arbitrary exit 1 or JSON object as proof of correct planning.
Before adding the journey, define exact effective bindings and typed expected
status, then capture the action and provider-visible result.

## Gotchas

A clean test-base clone has no installed skhd or Macarchy setup. Its runtime refusal
is not pinned by the source alone. Do not install packages or grant permissions to
manufacture a pass without a scoped, reviewed scenario. CLI inspection would still
not prove the viewer or that a shortcut fires.

`Scripts/verify-keybindings-portability.sh` and `KeybindingPortabilityTests`
create FIFOs. They run only in the disposable guest, never on a physical Mac
(see `AGENTS.md`).
