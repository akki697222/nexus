---@meta

-- ============================================================
--  Nexus OS — Service Manager  (srv/mgr.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Service definition
-- ------------------------------------------------------------

---@alias service_kind
---| '"core"'    # Core service: failure triggers panic
---| '"system"'  # System service: failure triggers automatic restart

---@class service_def
---@field id      string        # Unique service identifier (e.g. "storage", "filesystem")
---@field path    string        # Path to the service Lua file (e.g. "/Services/storage.lua")
---@field kind    service_kind
---@field deps    string[]?     # IDs of services that must be running before this one starts

-- ------------------------------------------------------------
--  Service entry (runtime state)
-- ------------------------------------------------------------

---@alias service_state
---| '"stopped"'   # Not yet started or terminated
---| '"starting"'  # Spawned, waiting for ready signal
---| '"running"'   # Fully started and operational
---| '"crashed"'   # Terminated unexpectedly, pending restart

---@class service_entry
---@field def     service_def
---@field pid     integer?       # PID of the running process (nil if stopped)
---@field state   service_state

-- ------------------------------------------------------------
--  Service Manager API
-- ------------------------------------------------------------

---@class service_manager
service_manager = {}

---Register a service definition.
---Must be called before start() or start_all().
---@param def service_def
---@return nil
function service_manager.register(def) end

---Start a single service by id.
---Blocks until all deps are running, then spawns the service process.
---Errors if the service is already running or its deps cannot be satisfied.
---@param id string
---@return nil
function service_manager.start(id) end

---Start all registered services in dependency order.
---Called by the kernel during boot.
---@return nil
function service_manager.start_all() end

---Stop a service by id.
---Kills the process and sets state to "stopped".
---Does not restart automatically.
---@param id string
---@return nil
function service_manager.stop(id) end

---Return the runtime entry for a service.
---@param id string
---@return service_entry?
function service_manager.get(id) end

---Return whether a service is currently in "running" state.
---@param id string
---@return boolean
function service_manager.is_running(id) end

---Mark a service as ready.
---Called by the service process itself once initialisation is complete.
---Transitions state from "starting" to "running".
---@param id string
---@return nil
function service_manager.ready(id) end

---Handle a process_died event for a managed service.
---Called internally by the kernel when a process_died event is received.
---Core services trigger panic; system services are automatically restarted.
---@param pid integer
---@return nil
function service_manager.on_process_died(pid) end

return service_manager