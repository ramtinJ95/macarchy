### Fixed

- Let setup teardown restore the original desktop after theme switches and undo,
  while preserving user changes and themes that existed before setup. Concurrent
  switches refuse retirement with a retry message.
- Avoid reconciling absent default consumers during unified teardown when its
  canonical theme is about to be retired.
- Keep a fresh theme activation and its native values when recovering teardown
  after the previous canonical theme was already retired.
- Read back a transient system-default wallpaper response before teardown calls it
  a user change; persistent user-selected wallpapers remain untouched.
