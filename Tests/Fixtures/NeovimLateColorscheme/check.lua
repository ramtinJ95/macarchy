-- nvim --clean --headless -i NONE -l Tests/Fixtures/NeovimLateColorscheme/check.lua <repository>
-- with XDG_CONFIG_HOME set to an empty temporary directory.
local repository = arg[1] or "."
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local config = vim.fn.stdpath("config")
vim.fn.mkdir(config .. "/lua/macarchy", "p")
vim.fn.writefile({
  'return { generation_id = "g1", theme_id = "catppuccin-mocha", colorscheme = "catppuccin-mocha" }',
}, config .. "/lua/macarchy/current.lua")
local colors = vim.fn.tempname()
vim.fn.mkdir(colors .. "/colors", "p")
vim.fn.writefile(
  { "vim.cmd.highlight('clear')", "vim.g.colors_name = 'catppuccin-mocha'" },
  colors .. "/colors/catppuccin-mocha.lua"
)
vim.opt.runtimepath:append(colors)

local source = table.concat(
  vim.fn.readfile(repository .. "/Environment/neovim/theme/lua/config/macarchy-theme.lua"),
  "\n"
)
local function load_theme()
  local patched = source:gsub("__MACARCHY_STATE_ROOT_LUA__", string.format("%q", root))
  local theme = assert(loadstring(patched))()
  theme.startup_window_ms = 100
  return theme
end
local function settles_on(name)
  return vim.wait(1000, function() return vim.g.colors_name == name end, 10)
end

-- Neovim starts with Macarchy's colorscheme and a plugin replaces it after VimEnter.
local theme = load_theme()
vim.cmd.colorscheme("catppuccin-mocha")
theme.watch()
vim.api.nvim_exec_autocmds("VimEnter", {})
vim.cmd.colorscheme("habamax")
assert(settles_on("catppuccin-mocha"), "a colorscheme a plugin picked after startup was kept")

-- After the window, the colorscheme the user picks stays.
vim.cmd.colorscheme("habamax")
vim.wait(300)
assert(vim.g.colors_name == "habamax", "a colorscheme picked after the window was replaced")

-- A colorscheme the user's configuration picked before VimEnter stays.
local configured = load_theme()
vim.cmd.colorscheme("habamax")
configured.watch()
vim.api.nvim_exec_autocmds("VimEnter", {})
vim.wait(300)
assert(vim.g.colors_name == "habamax", "the configuration's own colorscheme was replaced")

vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.fn.delete(root, "rf")
vim.fn.delete(colors, "rf")
print("Late colorscheme checks passed")
