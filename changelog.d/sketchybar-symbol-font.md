### Fixed

- Render the stock SketchyBar icons with the normally provisioned Meslo Nerd Font instead of assuming SF Pro is installed. Bar-only setups now require that font even with Kitty disabled.
- Bound post-install exact-font registration checks so normal cask publication delay does not abort fresh setup; unconfirmed registration remains an explicit failure with installed-package evidence retained.
