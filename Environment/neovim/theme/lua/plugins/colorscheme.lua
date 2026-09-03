local macarchy = require("config.macarchy-theme")
local current = macarchy.watch()

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    commit = "edefef779ab08ce1a4a404713e3012b0d202bd35",
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "mocha",
      transparent_background = true,
    },
  },
  {
    "folke/tokyonight.nvim",
    commit = "cdc07ac78467a233fd62c493de29a17e0cf2b2b6",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = true,
    },
  },
  {
    "rebelot/kanagawa.nvim",
    commit = "bb85e4bfc8d89b0e62c8fa53ccdd13d12e2f77b3",
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
