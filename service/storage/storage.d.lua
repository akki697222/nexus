---@meta

-- ============================================================
--  Nexus OS — Storage Service  (/Services/storage.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Volume entry
-- ------------------------------------------------------------

---@class volume_entry
---@field alias  string  # Drive alias (e.g. "System", "Data")
---@field addr   string  # OC filesystem component address
---@field proxy  table   # OC component proxy

-- ------------------------------------------------------------
--  Storage API
-- ------------------------------------------------------------

---@class storage
local storage = {}

---Mount a filesystem component under the given alias.
---alias must match [A-Za-z0-9_]+.
---Errors if the alias is already in use or the component does not exist.
---@param addr   string  # OC filesystem component address
---@param alias  string  # Drive alias (without "://")
---@return nil
function storage.mount(addr, alias) end

---Unmount the volume with the given alias.
---Has no effect if the alias is not mounted.
---@param alias string
---@return nil
function storage.unmount(alias) end

---Resolve a drive-alias path to an internal /Volumes/ path.
---e.g. "System://bin/shell.lua" → "/Volumes/<addr>/bin/shell.lua"
---Errors if the alias is not mounted.
---@param path string
---@return string
function storage.resolve(path) end

---Return a snapshot of all mounted volumes.
---@return table<string, volume_entry>  # alias -> volume_entry
function storage.list_volumes() end

---Return the volume entry for the given alias.
---Returns nil if not mounted.
---@param alias string
---@return volume_entry?
function storage.get_by_alias(alias) end

---Return the volume entry for the given component address.
---Returns nil if not mounted.
---@param addr string
---@return volume_entry?
function storage.get_by_addr(addr) end

return storage