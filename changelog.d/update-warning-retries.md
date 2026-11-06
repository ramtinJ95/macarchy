### Fixed

- The update warning beside the SketchyBar clock no longer stays up for six hours
  after one failed check, such as while the network is still reconnecting after
  wake. The bar retries a failed check after 15 minutes, clicking the warning
  retries it straight away, and the details read "The Internet connection appears
  to be offline" instead of a raw system error.
