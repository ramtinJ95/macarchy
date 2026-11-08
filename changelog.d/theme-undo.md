### Added

- `macarchy theme undo` and the action menu's "Undo last theme change" return to the
  theme and background that were active before the last change. Macarchy keeps the
  last 50 committed changes in `state/theme-history.json`; there is no redo.
