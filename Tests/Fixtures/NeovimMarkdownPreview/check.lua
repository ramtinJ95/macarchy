-- Run from the repository root: nvim --clean --headless -i NONE -l Tests/Fixtures/NeovimMarkdownPreview/check.lua
local notices = {}
vim.notify = function(message) table.insert(notices, message) end
vim.g.colors_name = nil
local preview = dofile("Environment/neovim/default/lua/config/markdown-preview.lua")
preview.setup()
assert(vim.g.mkdp_highlight_css == nil)
vim.api.nvim_set_hl(0, "Normal", { fg = "#abcdef", bg = "#123456" })
vim.api.nvim_set_hl(0, "Keyword", { fg = "#fedcba" })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local path = vim.g.mkdp_highlight_css
local function css() return table.concat(vim.fn.readfile(path), "\n") end
assert(css():find("color: #abcdef; background: #123456;", 1, true))
assert(css():find(".hljs-keyword, .hljs-selector-tag { color: #fedcba; }", 1, true))
assert(#notices == 0)
vim.g.mkdp_clients_active = 1
vim.api.nvim_set_hl(0, "Normal", { fg = "#112233", bg = "#ddeeff" })
vim.api.nvim_exec_autocmds("ColorScheme", {})
assert(vim.g.mkdp_highlight_css == path)
assert(css():find("color: #112233; background: #ddeeff;", 1, true))
assert(not css():find("#abcdef", 1, true))
assert(#notices == 1 and notices[1]:find("reload", 1, true))
local writefile = vim.fn.writefile
vim.fn.writefile = function() return -1 end
local callback = vim.api.nvim_get_autocmds({ group = "MacarchyMarkdownPreview", event = "ColorScheme" })[1].callback
local ok, failure = pcall(callback)
vim.fn.writefile = writefile
assert(not ok and tostring(failure):find("cannot write preview CSS", 1, true))
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(vim.fn.filereadable(path) == 0)
print("Markdown preview theme, refresh notice, failure and cleanup checks passed")
