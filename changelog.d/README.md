# Changelog fragments

Each user-facing change adds one `<any-name>.md` file here instead of editing
`CHANGELOG.md`, so merging one PR never conflicts with the next. A fragment holds
one Keep a Changelog section heading followed by bullets in the `CHANGELOG.md`
style, with continuation lines indented by two spaces:

```markdown
### Fixed

- Setup apply no longer rolls back when the playing song's title contains a
  quotation mark.
```

Sections: Added, Changed, Deprecated, Removed, Fixed, Security, Known
limitations. `python3 -B Scripts/changelog.py check` validates fragments, and
`Scripts/release.py prepare` folds them into `CHANGELOG.md` and deletes them.
