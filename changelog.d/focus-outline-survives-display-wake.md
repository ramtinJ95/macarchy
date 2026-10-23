### Fixed

- The lean focus outline no longer disappears for good when the window server
  briefly gives inconsistent answers, such as while a display wakes. Its helper
  quit with "the active menu-bar display is absent from the managed display
  Spaces" and stayed stopped until its service was restarted. It now hides the
  outline and retries, logging one line when such an outage starts and one when
  it ends.
