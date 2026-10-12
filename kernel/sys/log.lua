-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type log
log = {}

log.level = {
    info  = 0,
    warn  = 1,
    error = 2,
    debug = 3,
    panic = 4,
}

---Set to false once a terminal owns the screen (file logging continues).
log.screen = true

log.level_names = {
    [0] = "Info",
    [1] = "Warn",
    [2] = "Error",
    [3] = "Debug",
    [4] = "Panic"
}

local LOG_PATH       = "/debug.log"
local FLUSH_BYTES    = 1024      -- flush when buffered text exceeds this
local FLUSH_INTERVAL = 1.0       -- seconds; flushed from the scheduler loop
local MAX_FILE_BYTES = 256 * 1024 -- stop writing after this (OC disk / write cost)
local MAX_BUF_BYTES  = 8 * 1024  -- hard cap on RAM used by pending lines

local gpu = nil
local w, h, cy = -1, -1, 0

local file_addr, file_handle
local file_bytes   = 0
local file_full    = false
local buf, buf_len = {}, 0
local last_flush   = 0

local function file_flush()
    if not file_handle or buf_len == 0 then return end
    local data = table.concat(buf)
    buf, buf_len = {}, 0
    last_flush = computer.uptime()
    if file_full then return end
    if file_bytes + #data > MAX_FILE_BYTES then
        data = data:sub(1, MAX_FILE_BYTES - file_bytes) .. "\n[log truncated: size limit]\n"
        file_full = true
    end
    file_bytes = file_bytes + #data
    -- one write call per flush; keep chunks small (OC write buffer limits)
    for i = 1, #data, 2048 do
        local ok = pcall(component.invoke, file_addr, "write", file_handle, data:sub(i, i + 2047))
        if not ok then
            file_handle = nil
            return
        end
    end
end

local function file_append(line)
    if not file_handle then return end
    buf[#buf + 1] = line
    buf_len = buf_len + #line
    if buf_len >= FLUSH_BYTES or buf_len >= MAX_BUF_BYTES then
        file_flush()
    end
end

---Flush pending log lines to disk (called periodically by the scheduler).
function log.flush()
    file_flush()
end

---Flush only when FLUSH_INTERVAL has passed since the last flush.
function log.tick()
    if buf_len > 0 and computer.uptime() - last_flush >= FLUSH_INTERVAL then
        file_flush()
    end
end

---Open the log file on the boot filesystem (truncates the previous log).
function log.init_file()
    local ok, addr = pcall(computer.getBootAddress)
    if not ok or not addr then return end
    local ok2, handle = pcall(component.invoke, addr, "open", LOG_PATH, "w")
    if not ok2 or not handle then return end
    file_addr, file_handle = addr, handle
    file_bytes, file_full = 0, false
    buf, buf_len = {}, 0
    last_flush = computer.uptime()
end

function log.init(gpu_, screen_)
    arg(1, gpu_, "table")
    arg(2, screen_, "string")
    gpu = gpu_
    cy = 0
    gpu.bind(screen_, true)
    w, h = gpu.maxResolution()
    gpu.setResolution(w, h)
    gpu.setDepth(gpu.maxDepth())
    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, w, h, " ")
    log.init_file()
end

local function screen_write(text)
    if not gpu then return end
    while #text > 0 do
        local l = text:sub(1, w)
        text = text:sub(#l + 1)
        cy = cy + 1
        if cy > h then
            gpu.copy(1, 2, w, h - 1, 0, -1)
            gpu.fill(1, h, w, 1, " ")
            cy = h
        end
        gpu.set(1, cy, l)
    end
end

function log.kernel_log(level, fmt, ...)
    if not gpu then
        error("logger not initialized", 2)
    end
    local ok, formatted = pcall(string.format, fmt, ...)
    if not ok then
        formatted = tostring(fmt) .. " [bad log format: " .. tostring(formatted) .. "]"
    end

    local pid = scheduler and scheduler.current() or 0
    formatted = string.format("|%7.2f: [%s] [p%d] %s", computer.uptime() or -1, log.level_names[level], pid, formatted)
    formatted = formatted:gsub("\t", "    ")

    file_append(formatted .. "\n")
    if level >= 2 then
        file_flush()   -- errors / panics must survive a crash
    end

    if log.screen then
        for text in formatted:gmatch("[^\n]+") do
            screen_write(text)
        end
    end
end

function log.info(fmt, ...)
    log.kernel_log(0, fmt, ...)
end

function log.warn(fmt, ...)
    log.kernel_log(1, fmt, ...)
end

function log.error(fmt, ...)
    log.kernel_log(2, fmt, ...)
end

function log.debug(fmt, ...)
    log.kernel_log(3, fmt, ...)
end

function log.panic(fmt, ...)
    log.kernel_log(4, fmt, ...)
end
