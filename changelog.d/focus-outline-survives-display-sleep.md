### Fixed

- The lean focus outline no longer disappears for good when the display sleeps or the
  screen locks. While no app is in front it stays hidden, and it comes back once one
  is. Before, its helper quit with "_SLPSGetFrontProcess failed (-600)" and stayed
  stopped until its service was restarted.
