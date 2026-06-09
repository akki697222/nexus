---@meta

-- ============================================================
--  Nexus OS — Process Manager  (sys/proc/mgr.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Process Manager API
-- ------------------------------------------------------------

---@class process_manager
process_manager = {}

---Spawn a new process from a Lua file.
---The child inherits the parent's capability set.
---@param opts spawn_opts
---@return integer pid
function process_manager.spawn(opts) end

---Kill a process immediately.
---Recursively kills all children unless they are detached.
---Detached children are re-parented to init (pid 0).
---Triggers capability cleanup and router.unsubscribe().
---@param pid     integer
---@param reason  string?  # "killed" if omitted
---@return nil
function process_manager.kill(pid, reason) end

---Called internally when a coroutine finishes or errors.
---Performs the same cleanup as kill() but with reason "exit" or "error".
---@param pid     integer
---@param reason  '"exit"' | '"error"'
---@param code    integer?
---@return nil
function process_manager.reap(pid, reason, code) end

---Return the process table for the given PID.
---@param pid integer
---@return process?
function process_manager.get(pid) end

---Return the PID of the currently executing process.
---Delegates to scheduler.current().
---@return integer
function process_manager.self() end

---Return the process table of the currently executing process.
---@return process
function process_manager.current_proc() end

---Return all direct children of a process.
---@param pid integer
---@return integer[]
function process_manager.children(pid) end

---Re-parent a process to init (pid 0).
---Used when a detached process's parent dies.
---@param pid integer
---@return nil
function process_manager.adopt(pid) end

---Return a snapshot of all live processes.
---@return table<integer, process>
function process_manager.list() end

return process_manager