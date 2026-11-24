### Changed

- Guided setup installs selected components before Accessibility guidance and
  checks the Apple-menu helper from the running SketchyBar context. Missing
  post-configuration grants leave an explicit, resumable incomplete state.
- Teardown and interrupted-operation recovery do not require apply-only
  external capabilities, such as native menu-bar auto-hide, to restore owned state.
- Setup status and doctor avoid a debug-build stack overflow during nested planning.
- Setup review and diagnostics distinguish saved profiles from applied
  configuration, retain failing paths, and lead with recovery guidance.

- Setup proactively checks System Events Automation without changing appearance.
  Appearance uses fixed public Apple Events with no osascript fallback.
  Guided consent and explicit browser/menu choices can request native consent;
  background operations never prompt. Custom interactive CLI bindings can opt
  in with --allow-automation-consent.
- Automation results state their launch-context scope. A terminal grant does not
  prove skhd or bar/menu access; an interactive light/dark change from the failing
  context can request its own native consent.

- Known limitation: fresh-account TCC attribution and existing osascript-grant carry-over still
  require real-hardware verification. Terminal setup cannot verify
  keybinding-origin Automation through a read-only check. Terminal setup/status/doctor
  report that context as unverified, even if access was granted elsewhere.
