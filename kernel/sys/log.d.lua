---@meta

-- ============================================================
--  Nexus OS — Logger  (sys/log.lua)
-- ============================================================

-- ------------------------------------------------------------
--  Log levels
-- ------------------------------------------------------------

---@alias log_level
---| 0 # info
---| 1 # warn
---| 2 # error
---| 3 # debug
---| 4 # panic

-- ------------------------------------------------------------
--  Log API
-- ------------------------------------------------------------

---@class log
log = {}

---Log level constants.
---@type { info: 0, warn: 1, error: 2, debug: 3, panic: 4 }
log.level = {
    info  = 0,
    warn  = 1,
    error = 2,
    debug = 3,
    panic = 4,
}

---Initialize and reset logger with specified gpu.
---@param gpu oc_component_gpu
---@param screen string
---@return nil
function log.init(gpu, screen) end

---Write a log entry at the given level.
---fmt is interpreted as a string.format pattern.
---@param level log_level
---@param fmt   string
---@param ...   any
---@return nil
function log.kernel_log(level, fmt, ...) end

---Write an info-level log entry.
---@param fmt string
---@param ... any
---@return nil
function log.info(fmt, ...) end

---Write a warn-level log entry.
---@param fmt string
---@param ... any
---@return nil
function log.warn(fmt, ...) end

---Write an error-level log entry.
---@param fmt string
---@param ... any
---@return nil
function log.error(fmt, ...) end

---Write a debug-level log entry.
---@param fmt string
---@param ... any
---@return nil
function log.debug(fmt, ...) end

---Write a panic-level log entry.
---@param fmt string
---@param ... any
---@return nil
function log.panic(fmt, ...) end

return log