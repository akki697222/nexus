---@meta

-- ============================================================
--  Nexus OS — IPC  (sys/ipc/ipc.lua)
-- ============================================================

-- ------------------------------------------------------------
--  IPC API
-- ------------------------------------------------------------

---@class ipc
ipc = {}

---Send a message to a process.
---Internally calls router.push_to() with an ipc_event.
---Any Lua value is transferable: table, function, coroutine, capability, userdata.
---@param pid  integer
---@param data table
---@return nil
function ipc.send(pid, data) end

---Return whether the given PID is a live process.
---Useful before sending to avoid pushing into a dead process's queue.
---@param pid integer
---@return boolean
function ipc.is_alive(pid) end

return ipc