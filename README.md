# Macarchy

Macarchy is a native, theme-driven macOS desktop shell. The first release is
building one canonical palette and command surface for the existing desktop;
native shell surfaces follow only after that theme system is proven.

Macarchy is independently authored and inspired by the broader
[Omarchy](https://omarchy.org/) project. It is not an official port.

## Development

Requirements: Apple Silicon macOS 26 and Swift 6.

```sh
swift test
swift run macarchy theme list
swift run macarchy theme set catppuccin-mocha --dry-run
swift run macarchy theme next --dry-run
swift run macarchy theme status --json
```

`theme set` and `theme next` read built-in packages from `./Themes` and user
packages from `<state-root>/themes`. The state root defaults to
`~/.config/macarchy`. Before
activation, Kitty's configuration must contain an `include` for the expanded
absolute path `<state-root>/current/generated/kitty.conf`; Macarchy does not
edit Kitty's behavioral configuration. Use `--state-root` and `--kitty-config`
to inject development paths. `--dry-run` validates rendering and this include
without writing state or running a reload command. `theme next` follows the
validated package order and wraps at the end. `theme status` reads the
canonical generation manifest first and reports current, missing, stale, or
unreadable reconciliation state without treating it as active-theme truth.
Status exits nonzero when canonical state is absent or unreadable, status is
missing or stale, or a required adapter is not accepted; optional adapter
failure remains visible without making status unhealthy.

Tests use temporary roots and never access `~/.config/macarchy`.

The package input schema and versioned normalized palette contract are documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

Macarchy is available under the [MIT License](LICENSE). Bundled wallpaper
provenance and licensing are recorded inside each theme package.
