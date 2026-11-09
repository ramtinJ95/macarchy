### Fixed

- User-script interruption now stops children and re-sends the default signal to
  Macarchy's process without returning to application work, avoiding an intermittent
  swallowed interrupt on macOS worker threads.
