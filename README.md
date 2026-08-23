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
```

During M1, `theme set` only accepts `--dry-run`; canonical activation starts in
M2. The command reads built-in packages from `./Themes` by default. Tests inject
temporary theme and output roots and never access `~/.config/macarchy`.

The package input schema and versioned normalized palette contract are documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

Macarchy is available under the [MIT License](LICENSE). Bundled wallpaper
provenance and licensing are recorded inside each theme package.
