---@meta

-- ============================================================
--  Nexus OS — Scheduler  (sys/proc/sched.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Process state
-- ------------------------------------------------------------

---@alias process_state
---| '"running"'  # Currently executing or ready to resume
---| '"waiting"'  # Blocked, waiting for an event
---| '"sleeping"' # Blocked until a timer fires
---| '"dead"'     # Terminated, pending cleanup

-- ------------------------------------------------------------
--  Process
-- ------------------------------------------------------------

---@class process
---@field pid          integer               # Process ID
---@field parent       integer               # Parent PID (0 = init)
---@field children     integer[]             # Child PIDs
---@field coroutine    thread                # Underlying Lua coroutine
---@field state        process_state         
---@field caps         table                 # Capability set (cap_id -> capability)
---@field event_queue  event[]               # Incoming event buffer
---@field env          table<string, string> # Environment variables
---@field cwd          string                # Current working directory (e.g. "SYS://")
---@field detached     boolean               # If true, adopted by init on parent death

-- ------------------------------------------------------------
--  Spawn options
-- ------------------------------------------------------------

---@class spawn_opts
---@field path      string                 # Path to the Lua file to execute
---@field args      any[]?                 # Arguments passed to the process
---@field env       table<string, string>? # Environment variables (inherits parent if nil)
---@field detached  boolean?               # Detached mode (default: false)

-- ------------------------------------------------------------
--  Scheduler API
-- ------------------------------------------------------------

---@class scheduler
scheduler = {}

---Start the scheduler main loop.
---This function does not return under normal operation.
---@return nil
function scheduler.run() end

---Resume a specific process for one tick.
---Called internally by the scheduler loop.
---@param pid integer
---@return boolean ok
---@return string? err
function scheduler.resume(pid) end

---Yield the current process, returning control to the scheduler.
---@return nil
function scheduler.yield() end

---Put the current process to sleep for the given duration.
---Internally registers a timer event and moves the process to "sleeping" state.
---@param seconds number
---@return nil
function scheduler.sleep(seconds) end

---Register a new process with the scheduler.
---Called by Process Manager after spawning a coroutine.
---@param proc process
---@return nil
function scheduler.register(proc) end

---Remove a process from the scheduler.
---Called by Process Manager after a process reaches "dead" state.
---@param pid integer
---@return nil
function scheduler.unregister(pid) end

---Move a process from "waiting" to "running" state.
---Called by the router when an event arrives for a waiting process.
---@param pid integer
---@return nil
function scheduler.wake(pid) end

---Return the PID of the currently executing process.
---@return integer
function scheduler.current() end

return scheduler