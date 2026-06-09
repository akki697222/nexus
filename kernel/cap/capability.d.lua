---@meta

-- ============================================================
--  Nexus OS — Capability System  (cap/capability.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Cap (driver-registered capability definition)
-- ------------------------------------------------------------

---Ops map registered by a driver or service.
---Integer-keyed string values are standalone op names.
---String-keyed table values are named op groups containing op names.
---@alias cap_ops_map table<string|integer, string|table<integer,string>>

---Capability definition registered by a driver or service at boot time.
---@class cap_def
---@field ops      cap_ops_map                        Available ops and op groups.
---@field new      fun(): cap_core                    Create a new core object.
---@field dispose  fun(core: cap_core): boolean       Release a core object's resources.

-- ------------------------------------------------------------
--  Internal: cap_core and shared metatable
-- ------------------------------------------------------------

---The underlying resource object created by cap_def.new().
---Contains the actual op functions as fields.
---Shared across all cap_obj instances derived from the same capability.
---@class cap_core
---@field [string] function  Op functions exposed to cap_obj via __index.

---Shared metatable used by all cap_obj instances of the same capability.
---Revocation is performed by setting mt.__index = nil, which immediately
---invalidates all instances without touching each one individually.
---@class cap_mt
---@field __index cap_core|nil  Points to cap_core while valid; nil after revoke.

-- ------------------------------------------------------------
--  CapObj (instance returned to the process)
-- ------------------------------------------------------------

---A capability object instance returned by capability.create().
---An empty table with a shared cap_mt as its metatable.
---Op functions are accessed via __index → cap_core while the cap is valid.
---After revocation, __index is nil and any op access raises an error.
---@class cap_obj

-- ------------------------------------------------------------
--  Resolved ops
-- ------------------------------------------------------------

---Flat set of permitted op names, used during cap_core filtering.
---@alias resolved_ops table<string, true>

-- ------------------------------------------------------------
--  Capability API
-- ------------------------------------------------------------

---@class capability
capability = {}

---Register a cap_def under the given id.
---Called by drivers and services at boot time.
---@param id  string   Unique capability type identifier (e.g. "gpu", "filesystem").
---@param def cap_def
---@return nil
function capability.register(id, def) end

---Return the registered cap_def for the given id.
---Errors if the id is not registered.
---@param id string
---@return cap_def
function capability.get(id) end

---Resolve an ops specifier against a cap_def into a flat set.
---Expands op groups, deduplicates, and validates all names.
---If ops is nil, resolves to all standalone op names in cap_def.ops.
---Errors if any op name or group name does not exist in cap_def.ops.
---@param def cap_def
---@param ops (string|string[])[]|nil  Mixed list of op names and group names.
---@return resolved_ops
function capability.resolve_ops(def, ops) end

---Create a cap_obj instance for the given capability id.
---Internally:
---  1. Calls cap_def.new() to get a cap_core.
---  2. Builds a filtered cap_core containing only the resolved ops.
---  3. Creates a shared cap_mt with __index = filtered cap_core.
---  4. Returns setmetatable({}, mt) as the cap_obj.
---All instances sharing the same mt are revoked together via capability.revoke().
---@param id  string
---@param ops (string|string[])[]|nil
---@return cap_obj, cap_mt  # Returns both the instance and its shared mt for revocation.
function capability.create(id, ops) end

---Revoke a capability by invalidating its shared metatable.
---Sets mt.__index = nil, immediately invalidating all cap_obj instances
---that share this mt. Then calls cap_def.dispose(core).
---@param mt cap_mt
---@return nil
function capability.revoke(mt) end

---Return whether a cap_obj instance is still valid.
---@param instance cap_obj
---@return boolean
function capability.is_valid(instance) end

return capability