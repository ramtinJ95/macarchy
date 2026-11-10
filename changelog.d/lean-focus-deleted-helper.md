### Fixed

- Plain `brew upgrade` no longer leaves setup and doctor blocked when Homebrew
  deletes a still-running old lean focus helper. Matching owned job and PID/start
  evidence now identifies an outdated helper that setup apply can restart through
  its stable launch path; foreign or ambiguous processes still block repair.
