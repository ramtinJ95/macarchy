-- Invoked by EnvironmentNeovimMigrationTests with an explicitly supplied local
-- lazy.nvim checkout. No Neovim user config, plugins, or network tasks are run.
local lazy_root, sealed_lock = assert(arg[1]), assert(arg[2])
local config = vim.fn.stdpath("config")
local file = io.open(sealed_lock, "wb")
if file then file:close() end
assert(file == nil, "the immutable seed must remain read-only")
vim.opt.rtp:prepend(lazy_root)
package.loaded["lazy.core.config"] = {
  options = { lockfile = config .. "/lazy-lock.json" },
  plugins = {},
  spec = { disabled = {}, ignore_installed = {} },
}
-- Exercise Lazy's real lock writer, the shared completion path for its
-- install/update/restore/clean operations, against the migrated public path.
require("lazy.manage.lock").update()
local lock = assert(io.open(config .. "/lazy-lock.json", "r"))
assert(type(vim.json.decode(lock:read("*a"))) == "table")
lock:close()
print("Lazy lock writer succeeded; immutable seed stayed read-only")
