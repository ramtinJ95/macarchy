### Fixed

- Retain accent restoration ownership when a native write succeeds but its helper
  reply or confirmation record fails. Setup apply now reports the restored or kept
  accent after deferred commit, including interrupted-commit recovery.
