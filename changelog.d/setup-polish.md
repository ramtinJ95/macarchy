### Fixed

- Guided setup waits for System Events launch readiness and makes one
  nonprompting re-check after a process-not-found result, including after consent.
  Denial and timeouts remain explicit failures, never assumed grants.
- Setup review now summarizes packages, configuration backups, permissions and
  blockers instead of repeating the full inventory. Use `setup plan --full` or
  `setup guided --full` for details; JSON and status/doctor remain complete.
