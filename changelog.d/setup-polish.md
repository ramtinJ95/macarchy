### Fixed

- Guided setup waits for System Events launch readiness and makes one
  nonprompting re-check after a process-not-found result, including after consent.
  After native consent, bounded fresh-process read-only checks attempt to verify
  access; unconfirmed consent has an explicit state and recovery command.
  Denial and timeouts remain explicit failures, never assumed grants.
- Setup review now summarizes packages, configuration backups, permissions and
  blockers instead of repeating the full inventory. Every planned action remains
  visible, including user scripts and native accent/icon-style changes. Use
  `setup guided --resume --full` for a retained profile's full guided inventory,
  including starters/replacements; JSON and status/doctor remain complete.
