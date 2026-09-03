local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local result = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    error("Macarchy: cannot install lazy.nvim: " .. result)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    {
      "LazyVim/LazyVim",
      commit = "c10948c50b18fae7f256433afdef09e432410480",
      import = "lazyvim.plugins",
    },
    { import = "plugins" },
  },
  defaults = {
    lazy = false,
    version = false,
  },
  install = {
    colorscheme = { "catppuccin-mocha", "tokyonight-night", "kanagawa" },
  },
  checker = {
    enabled = false,
  },
  change_detection = {
    notify = false,
  },
})
