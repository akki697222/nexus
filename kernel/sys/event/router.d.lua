---@meta

-- ============================================================
--  Nexus OS — Event Router  (sys/event/router.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Event types
-- ------------------------------------------------------------

---@alias event_type
---| '"ipc"'                # Inter-process message
---| '"process_spawned"'    # Process creation notification
---| '"process_died"'       # Process termination notification
---| '"capability_revoked"' # Capability invalidation notification
---| '"device_added"'       # OC component added (hotplug)
---| '"device_removed"'     # OC component removed (hotplug)
---| '"timer"'              # Sleep / timeout timer
---| string                 # Any other event type

---@class event
---@field type event_type # Event type
---@field from integer?   # Sender PID (nil for system events)
---@field data table?     # Payload (optional)

---@class ipc_event : event
---@field type '"ipc"'
---@field from integer # Sender PID
---@field data table   # Message payload

---@class process_died_event : event
---@field type '"process_died"'
---@field pid integer    # PID of the terminated process
---@field reason string? # Termination reason: "exit" | "error" | "killed"
---@field code integer?  # Exit code

---@class device_event : event
---@field type '"device_added"' | '"device_removed"'
---@field addr string       # OC component address
---@field nexus_type string # Nexus device type ("display", "input", etc.)

---@class timer_event : event
---@field type '"timer"'
---@field id integer     # Timer ID

-- ------------------------------------------------------------
--  Filter
-- ------------------------------------------------------------

---Describes which events a process wants to receive.
---@class event_filter
---@field type  event_type? # Filter by event type (nil = accept all)
---@field from  integer?    # Filter by sender PID (nil = accept any)

-- ------------------------------------------------------------
--  Router API
-- ------------------------------------------------------------

---@class router
router = {}

---Push an event onto the bus.
---The event will be distributed to process queues on the next dispatch() call.
---@param event event
---@return nil
function router.push(event) end

---Process all pending events on the bus and deliver them to each process event_queue.
---Called by the Scheduler every tick.
---@return nil
function router.dispatch() end

---Register a process as an event receiver.
---Without a filter, the process receives all broadcast events.
---@param pid     integer
---@param filter  event_filter?
---@return nil
function router.subscribe(pid, filter) end

---Unregister a process from event delivery.
---Called by Process Manager on process exit.
---@param pid integer
---@return nil
function router.unsubscribe(pid) end

---Pop the next event from a process's event_queue.
---Returns nil if the queue is empty.
---@param pid integer
---@return event?
function router.pop(pid) end

---Return whether a process has pending events in its queue.
---@param pid integer
---@return boolean
function router.has_event(pid) end

---Unicast: push an event directly into a specific process's event_queue.
---Used internally by ipc.send().
---@param pid   integer
---@param event event
---@return nil
function router.push_to(pid, event) end

---Broadcast: deliver an event to all subscribed processes.
---Used for system events such as device_added, process_died, etc.
---@param event event
---@return nil
function router.broadcast(event) end

return router