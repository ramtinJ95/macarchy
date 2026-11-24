### Fixed

- Guided setup gives freshly installed theme tools bounded cold-start headroom.
  A read-only Atuin, eza or Starship verification timeout now retains configuration
  with a named incomplete result and reconciliation command; real errors still
  roll back, and required theme health remains unsuccessful until verified.
- Setup checks restored shell startup after unified configuration restoration,
  avoiding misleading missing-defaults warnings from an intermediate rollback.
- SketchyBar permission checks report Accessibility and Automation independently,
  with stage timings and explicit timeout/recheck guidance instead of checking
  indefinitely, even while the bar is hidden, without adding idle polling.
  Missing Automation is distinguished from a failed native probe.
- Yabai startup counts daemon instances rather than short-lived message clients
  sent by its configuration script, while retaining daemon identity and singleton
  checks.
