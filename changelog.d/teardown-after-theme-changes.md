### Fixed

- Let setup teardown restore the original desktop after theme switches and undo,
  while preserving user changes and themes that existed before setup. Concurrent
  switches refuse retirement with a retry message.
- Avoid reconciling absent default consumers during unified teardown when its
  canonical theme is about to be retired.
