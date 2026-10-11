---@meta

-- ============================================================
--  Nexus OS — Event API  (sys/event/event.lua)
-- ============================================================

---@class event_api
event = {}

---Pull the next event from the current process's event_queue.
---Yields the coroutine until an event matching the filter arrives.
---@param type     event_type?  Filter by event type (nil = accept all)
---@param timeout  number?      Seconds to wait before returning nil (nil = wait forever)
---@return event?
function event.pull(type, timeout) end

---Register a persistent listener for a given event type.
---callback is called every time a matching event is delivered to this process.
---Returns a handle that can be used to remove the listener.
---@param type     event_type
---@param callback fun(event: event)
---@return integer handle
function event.on(type, callback) end

---Remove a previously registered listener.
---@param handle integer
---@return nil
function event.off(handle) end

---Register a one-shot listener.
---Automatically removed after the first matching event.
---@param type     event_type
---@param callback fun(event: event)
---@return integer handle
function event.once(type, callback) end

return event