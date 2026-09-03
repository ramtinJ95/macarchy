local chunk, load_error =
  loadfile(__MACARCHY_STATE_ROOT_LUA__ .. "/current/generated/neovim.lua")
if not chunk then
  error(load_error)
end
return chunk()
