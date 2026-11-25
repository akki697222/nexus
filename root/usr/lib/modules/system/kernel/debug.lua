-- debug.lua - console debugging aids for development builds
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Release branches drop this module and its line in /etc/modules.lua; vt
-- and tty only keep the hooks it uses. Switched on in /boot/config.lua:
--   debug = true             a DEBUG label in the bottom right corner
--   console_vt_debug = true  the vt's state on the top row
--   tty_debug = true         one dmesg line per key signal and per input
--                            token a reader takes, with the uptime
local module = require("module")
local system = require("system")
local computer = require("computer")
local fs = require("filesystem")

-- Draws on the vt's off-screen buffer after its rows (setFg / setBg are
-- the vt's cached color setters) and returns the rows it drew over.
local function overlay(dev, gpu, setFg, setBg)
    local config = system.config
    local rows
    if config.console_vt_debug then
        local size = (fs.size and fs.size("/tmp/vtbuf")) or 0
        setFg(gpu, 0xFF0000)
        setBg(gpu, 0x000000)
        gpu.set(1, 1, string.format("CX:%d CY:%d W:%d H:%d BUF_N:%d LP:%d SCR:%d BUF:%d SIZE:%d",
            dev.cx, dev.cy, dev.width, dev.height, dev.buf_n or -1, #dev.line_positions,
            dev.scscroll, #dev.buf, size))
        rows = { 1 }
    end
    if config.debug then
        setFg(gpu, 0xFFFFFF)
        setBg(gpu, 0xFF0000)
        gpu.set(dev.width - 4, dev.height, "DEBUG")
        rows = rows or {}
        rows[#rows + 1] = dev.height
    end
    return rows
end

local function trace(fmt, ...)
    if system.config.tty_debug then
        system.printk(string.format("tty: %.2f " .. fmt, computer.uptime(), ...), "debug")
    end
end

local vt, tty

---@type kernel_module
return {
    load = function()
        vt = module.require("vt")
        tty = module.require("tty")
        if vt then vt.setDebugOverlay(overlay) end
        if tty then tty.setTrace(trace) end
    end,
    unload = function()
        if vt then vt.setDebugOverlay(nil) end
        if tty then tty.setTrace(nil) end
    end,
    module = {},
    manifest = {
        name = "debug",
        desc = "console debugging aids (development builds)",
        version_n = 1,
        version = "0.1.0-OC"
    }
}
