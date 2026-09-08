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
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/current", "p")
local function normalized(generation)
  vim.fn.writefile({ vim.json.encode({
    schema_version = 1, generation_id = generation, theme_id = "test",
    semantic = { background = "#1e1e2e" },
  }) }, root .. "/current/theme.json")
end
normalized("g-test")
local source = table.concat(vim.fn.readfile("Environment/neovim/theme/lua/config/macarchy-theme.lua"), "\n")
local theme = assert(loadstring(source:gsub("__MACARCHY_STATE_ROOT_LUA__", string.format("%q", root))))()
theme.current = function() return { generation_id = "g-test", theme_id = "test" } end
package.loaded["config.macarchy-theme"] = theme
vim.api.nvim_set_hl(0, "Normal", { fg = "#112233" })
vim.api.nvim_exec_autocmds("ColorScheme", {})
assert(css():find("color: #112233; background: #1e1e2e;", 1, true))
assert(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg == nil)
normalized("g-other")
local matched, mismatch = pcall(theme.background)
assert(not matched and tostring(mismatch):find("does not match", 1, true))
normalized("g-test")
local writefile = vim.fn.writefile
vim.fn.writefile = function() return -1 end
local callback = vim.api.nvim_get_autocmds({ group = "MacarchyMarkdownPreview", event = "ColorScheme" })[1].callback
local ok, failure = pcall(callback)
vim.fn.writefile = writefile
assert(not ok and tostring(failure):find("cannot write preview CSS", 1, true))
vim.api.nvim_exec_autocmds("VimLeavePre", {})
assert(vim.fn.filereadable(path) == 0)
vim.fn.delete(root, "rf")
print("Markdown preview theme, refresh notice, failure and cleanup checks passed")
