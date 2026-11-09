### Fixed

- Neovim keeps Macarchy's colorscheme when a plugin picks another one shortly after
  startup, for example on LazyVim's VeryLazy event. A colorscheme your own
  configuration sets, or one you pick after the first second, stays.
