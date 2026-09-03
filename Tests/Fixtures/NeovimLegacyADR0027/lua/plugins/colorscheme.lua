local macarchy = require("config.macarchy-theme")
local current = macarchy.watch()

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "mocha",
      transparent_background = true,
    },
  },
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = true,
    },
  },
  {
    "rebelot/kanagawa.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      theme = "wave",
      transparent = true,
    },
  },
  {
    "omacom-io/aether.nvim",
    branch = "v3",
    commit = "567efb778534e11ee1072d4fe27178f705a27d8a",
    name = "aether",
    lazy = false,
    priority = 1000,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = current.colorscheme,
    },
  },
}
