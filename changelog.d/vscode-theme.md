### Added

- Opt-in VS Code, Cursor, VSCodium and Windsurf (Devin Desktop) theming through a
  generated Macarchy extension and comment-preserving default-profile settings.
  Teardown restores the owned settings and uninstalls the owned extension;
  non-default profiles and workspace overrides remain user-controlled.
  VS Code extension updates require the user's **Developer: Reload Window**;
  Macarchy never reloads or restarts an editor.
  Inherited CLI profile/extension redirects are removed, portable installations
  are refused, and timed-out CLI wrappers stop their owned process groups.
