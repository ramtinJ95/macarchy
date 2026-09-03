local M = {}
local state = {}

local root = vim.fn.expand("~/.config/macarchy")
local current_path = vim.fn.stdpath("config") .. "/lua/macarchy/current.lua"
local imported_colorscheme = "macarchy-imported"
local runtime_names = {
  ["catppuccin-mocha"] = "catppuccin-mocha",
  ["kanagawa-wave"] = "kanagawa",
  [imported_colorscheme] = imported_colorscheme,
  ["tokyonight-night"] = "tokyonight-night",
}
local palette_keys = {
  "accent",
  "cursor",
  "foreground",
  "background",
  "selection_foreground",
  "selection_background",
  "bg",
  "lighter_bg",
  "selection",
  "muted",
  "dark_fg",
  "fg",
  "light_fg",
  "bright_fg",
  "red",
  "yellow",
  "orange",
  "green",
  "cyan",
  "blue",
  "purple",
  "brown",
  "dark_bg",
  "darker_bg",
  "bright_red",
  "bright_yellow",
  "bright_green",
  "bright_cyan",
  "bright_blue",
  "bright_purple",
}
local palette_key_set = {}
for _, key in ipairs(palette_keys) do
  palette_key_set[key] = true
end

local function valid_palette(palette)
  if type(palette) ~= "table" then
    return false
  end
  local count = 0
  for key, value in pairs(palette) do
    if not palette_key_set[key] or type(value) ~= "string" or not value:match("^#%x%x%x%x%x%x$") then
      return false
    end
    count = count + 1
  end
  return count == #palette_keys
end

local function valid_shape(theme)
  if
    type(theme) ~= "table"
    or type(theme.generation_id) ~= "string"
    or type(theme.theme_id) ~= "string"
    or not runtime_names[theme.colorscheme]
  then
    return false
  end
  for key in pairs(theme) do
    if key ~= "generation_id" and key ~= "theme_id" and key ~= "colorscheme" and key ~= "palette" then
      return false
    end
  end
  if theme.colorscheme == imported_colorscheme then
    return valid_palette(theme.palette)
  end
  return theme.palette == nil
end

local function read_current()
  local chunk, load_error = loadfile(current_path)
  if not chunk then
    error(load_error)
  end

  local ok, theme = pcall(chunk)
  if not ok then
    error(theme)
  end
  if not valid_shape(theme) then
    error("invalid generated Neovim theme")
  end
  return theme
end

local function same_theme(previous, current)
  if
    not previous
    or previous.theme_id ~= current.theme_id
    or previous.colorscheme ~= current.colorscheme
  then
    return false
  end
  if previous.palette == nil or current.palette == nil then
    return previous.palette == nil and current.palette == nil
  end
  for _, key in ipairs(palette_keys) do
    if previous.palette[key] ~= current.palette[key] then
      return false
    end
  end
  return true
end

function M.current()
  local ok, theme = pcall(read_current)
  if not ok then
    error("Macarchy: " .. theme)
  end
  return theme
end

function M.apply_imported()
  local theme = M.current()
  if theme.colorscheme ~= imported_colorscheme then
    error("Macarchy: imported colorscheme requested for a named theme")
  end
  local options = {
    name = imported_colorscheme,
    transparent = false,
    colors = theme.palette,
  }
  require("aether.config").setup(options)
  require("aether.theme").setup(options)
  return theme
end

function M.verify()
  local theme = M.current()
  if not state.watcher then
    error("Macarchy: canonical theme watcher is not active")
  end
  if vim.g.colors_name ~= runtime_names[theme.colorscheme] then
    error(
      "Macarchy: active colorscheme is "
        .. tostring(vim.g.colors_name)
        .. "; expected "
        .. runtime_names[theme.colorscheme]
    )
  end
  if theme.colorscheme == imported_colorscheme then
    local colors = require("aether.colorscheme")
    for _, key in ipairs(palette_keys) do
      if colors[key] ~= theme.palette[key] then
        error("Macarchy: active Aether palette does not match generated key " .. key)
      end
    end
  end
  return theme
end

local function apply_current()
  local ok, theme = pcall(read_current)
  if not ok then
    vim.notify("Macarchy: " .. theme, vim.log.levels.ERROR)
    return
  end
  if same_theme(state.theme, theme) then
    state.theme = theme
    return
  end

  local applied, apply_error = pcall(vim.cmd.colorscheme, theme.colorscheme)
  if not applied then
    vim.notify("Macarchy: " .. apply_error, vim.log.levels.ERROR)
    return
  end
  state.theme = theme
end

function M.watch()
  if state.watcher then
    return M.current()
  end

  local watcher = vim.uv.new_fs_event()
  local timer = vim.uv.new_timer()
  local started, start_error = watcher:start(root, {}, function(watch_error)
    if watch_error then
      vim.schedule(function()
        vim.notify("Macarchy: canonical theme watcher failed: " .. watch_error, vim.log.levels.ERROR)
      end)
      return
    end
    timer:stop()
    timer:start(50, 0, vim.schedule_wrap(apply_current))
  end)
  if not started then
    watcher:close()
    timer:close()
    error("Macarchy: cannot watch canonical theme state: " .. start_error)
  end

  state.watcher = watcher
  local read_ok, current = pcall(M.current)
  if not read_ok then
    watcher:stop()
    watcher:close()
    timer:close()
    state.watcher = nil
    error(current)
  end
  state.theme = current
  vim.api.nvim_create_autocmd("VimResume", { callback = apply_current })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      watcher:stop()
      timer:stop()
      watcher:close()
      timer:close()
    end,
  })
  return current
end

return M
