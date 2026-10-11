-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type timer
local timer = {}

---@type timer_handle[]
local pending = {}

---@type integer
local next_id = 1

function timer.after(seconds, callback)
    arg(1, seconds,  "number")
    arg(2, callback, "function")

    local handle = {
        id       = next_id,
        expires  = computer.uptime() + seconds,
        callback = callback,
    }
    next_id = next_id + 1
    pending[#pending + 1] = handle
    return handle
end

function timer.cancel(handle)
    arg(1, handle, "table")
    for i, h in ipairs(pending) do
        if h.id == handle.id then
            table.remove(pending, i)
            return
        end
    end
end

function timer.tick()
    local now  = computer.uptime()
    local keep = {}
    for _, h in ipairs(pending) do
        if now >= h.expires then
            local ok, err = pcall(h.callback)
            if not ok then
                log.warn("timer %d callback error: %s", h.id, tostring(err))
            end
        else
            keep[#keep + 1] = h
        end
    end
    pending = keep
end