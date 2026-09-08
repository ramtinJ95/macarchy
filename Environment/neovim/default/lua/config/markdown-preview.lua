-- Preview syntax follows the canonically selected editor colorscheme, not a fixed theme.
local M = {}

function M.setup()
  local path = vim.fn.tempname() .. ".css"
  local group = vim.api.nvim_create_augroup("MacarchyMarkdownPreview", { clear = true })
  local function refresh()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    assert(normal.fg, "Macarchy preview requires Normal foreground")
    local background = normal.bg or require("config.macarchy-theme").background()
    local function color(name)
      -- Unstyled syntax deliberately inherits normal text, just as it does in Neovim.
      return string.format("#%06x", vim.api.nvim_get_hl(0, { name = name, link = false }).fg or normal.fg)
    end
    local lines = {
      "/* Macarchy: derived from the active Neovim colorscheme. */",
      string.format("pre.hljs { color: #%06x; background: #%06x; }", normal.fg, background),
    }
    for _, rule in ipairs({
      { "Keyword", ".hljs-keyword, .hljs-selector-tag" },
      { "Statement", ".hljs-built_in, .hljs-doctag" },
      { "Type", ".hljs-type, .hljs-title.class_" },
      { "Number", ".hljs-number, .hljs-literal, .hljs-meta" },
      { "Operator", ".hljs-operator" },
      { "Identifier", ".hljs-property, .hljs-variable, .hljs-attr, .hljs-symbol" },
      { "String", ".hljs-string, .hljs-regexp, .hljs-attribute, .hljs-template-variable" },
      { "Function", ".hljs-title, .hljs-section" },
      { "Comment", ".hljs-comment, .hljs-quote" },
      { "DiffAdd", ".hljs-addition" },
      { "DiffDelete", ".hljs-deletion" },
    }) do
      table.insert(lines, rule[2] .. " { color: " .. color(rule[1]) .. "; }")
    end
    table.insert(lines, ".hljs-emphasis { font-style: italic; } .hljs-strong { font-weight: bold; }")
    assert(vim.fn.writefile(lines, path) == 0, "Macarchy: cannot write preview CSS")
    vim.g.mkdp_highlight_css = path
    vim.g.mkdp_theme = vim.o.background
    if vim.g.mkdp_clients_active == 1 then
      vim.notify("Macarchy: reload the Markdown preview page to display the new theme", vim.log.levels.INFO)
    end
  end
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = refresh })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function() vim.fn.delete(path) end,
  })
  if vim.g.colors_name then refresh() end
end

return M
