---@meta

-- ============================================================
--  Nexus OS — Timer  (sys/timer.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Timer handle
-- ------------------------------------------------------------

---@class timer_handle
---@field id       integer   # Unique timer ID
---@field expires  number    # computer.uptime() value at which the timer fires
---@field callback fun()     # Called when the timer expires

-- ------------------------------------------------------------
--  Timer API
-- ------------------------------------------------------------

---@class timer
timer = {}

---Register a one-shot timer.
---callback is called once after the given number of seconds.
---Returns a handle that can be used to cancel the timer.
---@param seconds  number
---@param callback fun()
---@return timer_handle
function timer.after(seconds, callback) end

---Cancel a pending timer.
---Has no effect if the timer has already fired or been cancelled.
---@param handle timer_handle
---@return nil
function timer.cancel(handle) end

---Check all pending timers and fire any that have expired.
---Called by the scheduler main loop every tick.
---@return nil
function timer.tick() end

return timer