### Fixed

- Guided setup gives freshly installed theme tools bounded cold-start headroom.
  A read-only Atuin, eza or Starship verification timeout now retains configuration
  with a named incomplete result and reconciliation command; real errors still
  roll back, and required theme health remains unsuccessful until verified.
- Setup checks restored shell startup after unified configuration restoration,
  avoiding misleading missing-defaults warnings from an intermediate rollback.
