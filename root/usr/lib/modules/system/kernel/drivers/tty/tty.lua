---@type devfs
local devfs = require("devfs")
---@type module
local module = require("module")
---@type vfs
local fs = require("filesystem") --[[@as vfs]]
---@type system
local system = require("system")
---@type process
local process = require("process")
---@type event
local event = require("event")

---@type tty_driver[]
local ttys = {}

---@class tty_driver : console_device
---@field device console_device|vt_driver|nil
local tty_driver = {
    id = -1,
    console = {
        -- 0=fbcon,1=vt
        major = 1,
        -- default to use ttyv1
        minor = -1
    },
    device = nil,
    -- for readmode
    buffer = "",      -- current line editing buffer
    read_buffer = "", -- committed input buffer
    pressing = {},
    pressingChars = {},
    reading = false,
    eof = false,
    flags = {
        canonical = true,
        disableWriteCharInput = false
    },
    in_pid = -1
}
tty_driver.__index = tty_driver

local stdin = 0
local stdout = 1
local stderr = 2

function tty_driver:init()
    local vt = module.require("vt")
    if not vt then
        local m, e = module.load("/usr/lib/modules/system/kernel/drivers/tty/vt.lua")
        if not m then
            system.printk("tty: failed to create vt: cannot load module: " .. e)
            return
        end
        vt = m.module
    end
    self.console.minor = self.id + 1
    self.device = vt.new(self.console.minor)
end

function tty_driver:read_pump(mask)
    self.reading = true
    while self.reading do
        local ev = { event.pull() }
        local etype = ev[1]
        local char = ev[3]
        local key = ev[4]

        if etype == "key_down" then
            if not self.pressing[key] then
                self.pressing[key] = true
                self.pressingChars[char] = true

                if self.flags.canonical then
                    if char == 13 then
                        -- Enter
                        self.read_buffer = self.read_buffer .. self.buffer .. "\n"
                        self.buffer = ""
                        self.device:write("\n")
                        self.reading = false
                    elseif char == 3 then
                        -- Ctrl+C (SIGINT)
                        local proc = process.get(self.in_pid)
                        if proc then
                            table.insert(proc.signals, 2)
                        end
                        self.buffer = ""
                        self.read_buffer = ""
                        self.reading = false
                    elseif char == 4 then
                        -- Ctrl+D (EOF)
                        if #self.buffer > 0 then
                            -- Push buffer without newline
                            self.read_buffer = self.read_buffer .. self.buffer
                            self.buffer = ""
                            self.reading = false
                        else
                            -- Real EOF
                            self.eof = true
                            self.reading = false
                        end
                    elseif char == 8 then
                        -- Backspace
                        if #self.buffer > 0 then
                            self.buffer = self.buffer:sub(1, -2)
                            if not self.flags.disableWriteCharInput then
                                self.device:backspace()
                            end
                        end
                    elseif char and char >= 32 and char <= 126 then
                        local c = string.char(char)
                        self.buffer = self.buffer .. c
                        if not self.flags.disableWriteCharInput then
                            -- handle mask
                            self.device:write(mask or c)
                        end
                    end
                else
                    if char and char ~= 0 then
                        self.read_buffer = self.read_buffer .. string.char(char)
                        self.reading = false
                    end
                end
            end
        elseif etype == "key_up" then
            self.pressing[key] = false
            self.pressingChars[char] = false
        elseif etype == "clipboard" then
            if not self.flags.canonical then
                self.read_buffer = self.read_buffer .. char
                if not self.flags.disableWriteCharInput then
                    self.device:write(mask or char)
                end
                self.reading = false
            end
        end
    end
end

function tty_driver:readBytes(n, mask)
    while #self.read_buffer < n do
        if self.eof then break end
        self:read_pump(mask)
    end
    if #self.read_buffer == 0 and self.eof then return nil end
    local count = math.min(n, #self.read_buffer)
    local out = self.read_buffer:sub(1, count)
    self.read_buffer = self.read_buffer:sub(count + 1)
    return out
end

function tty_driver:readLine(chop, mask)
    while not self.read_buffer:find("\n") do
        if self.eof then break end
        self:read_pump(mask)
    end
    local p = self.read_buffer:find("\n")
    if p then
        local line = self.read_buffer:sub(1, p - 1)
        if not chop then line = line .. "\n" end
        self.read_buffer = self.read_buffer:sub(p + 1)
        return line
    else
        if #self.read_buffer > 0 then
            local line = self.read_buffer
            self.read_buffer = ""
            return line
        end
        return nil
    end
end

function tty_driver:readNumber(mask)
    -- skip whitespace
    while true do
        if #self.read_buffer == 0 then
            if self.eof then break end
            self:read_pump(mask)
        end
        if #self.read_buffer == 0 and self.eof then return nil end

        if self.read_buffer:find("^%s") then
            self.read_buffer = self.read_buffer:gsub("^%s+", "")
        else
            break
        end
    end
    -- read digits
    local num_str = ""
    while true do
        if #self.read_buffer == 0 then
            if self.eof then break end
            self:read_pump(mask)
        end
        if #self.read_buffer == 0 and self.eof then break end

        local match = self.read_buffer:match("^(%d+)")
        if match then
            num_str = num_str .. match
            self.read_buffer = self.read_buffer:sub(#match + 1)
        else
            local next_char = self.read_buffer:sub(1, 1)
            if next_char:match("%D") then
                break
            end
        end
    end
    return tonumber(num_str)
end

function tty_driver:readAll(mask)
    if #self.read_buffer == 0 then
        if not self.eof then self:read_pump(mask) end
    end
    if #self.read_buffer == 0 and self.eof then return nil end
    local out = self.read_buffer
    self.read_buffer = ""
    while not self.eof do
        self:read_pump(mask)
        out = out .. self.read_buffer
        self.read_buffer = ""
    end
    return out
end

function tty_driver:read(...)
    self.in_pid = process.getCurrentPID()
    event.setForeground(self.in_pid)
    self.reading = true
    self.buffer = ""
    self.eof = false
    self.eof = false

    local formats = table.pack(...)
    if formats.n == 0 then formats = { "*l", n = 1 } end

    local results = {}
    local i = 1
    while i <= formats.n do
        local fmt = formats[i]
        local mask = nil
        -- Check for mask argument (single char string, e.g. "*")
        if i < formats.n then
            local next_arg = formats[i + 1]
            if type(next_arg) == "string" and #next_arg == 1 and not next_arg:match("[nlaL]") and next_arg == "*" then
                mask = next_arg
                i = i + 1
            end
        end

        local res
        if type(fmt) == "number" then
            res = self:readBytes(fmt, mask)
        elseif type(fmt) == "boolean" then
            res = self:readLine(true, mask)
        else
            local mode = fmt:gsub("^%*", "")
            if mode == "n" then
                res = self:readNumber(mask)
            elseif mode == "l" then
                res = self:readLine(true, mask)
            elseif mode == "L" then
                res = self:readLine(false, mask)
            elseif mode == "a" then
                res = self:readAll(mask)
            else
                error("bad argument #" .. i .. " (invalid format)")
            end
        end
        table.insert(results, res)
        i = i + 1
    end

    self.in_pid = -1
    return table.unpack(results)
end

function tty_driver:getViewport()
    return self.device:getViewport()
end

function tty_driver:setViewport(w, h, cx, cy)
    return self.device:setViewport(w, h, cx, cy)
end

function tty_driver:write(...)
    if not self.device then return end
    self.device:write(...)
end

function tty_driver:scroll(n)
    if not self.device then return end
    self.device:scroll(n)
end

function tty_driver:getCursor()
    return self.device:getCursor()
end

function tty_driver:setCursor(cx, cy)
    return self.device:setCursor(cx, cy)
end

---@class module_tty
local tty = {}

function tty.new(id)
    local dev = setmetatable({}, tty_driver)
    devfs.create("tty" .. tostring(id), dev)
    dev.id = id
    dev:init()
    ttys[id] = dev
    return dev
end

function tty.switch(id)
    local dev = tty.get(id)
    if not dev then return end
    local proc = process.getCurrent()
    proc.tty = id
    event.setForeground(proc.pid)
    if dev.device then
        dev.device.dirty = true
    end
end

function tty.getCurrent()
    local proc = process.getCurrent()
    local ttyid = proc and proc.tty or 0
    return tty.get(ttyid)
end

function tty.get(id)
    return ttys[id]
end

function tty.isCharPressing(char)
    return tty:getCurrent().pressingChars[char]
end

function tty.isKeyPressing(key)
    return tty:getCurrent().pressingChars[key]
end

function tty.getCursor()
    return tty.getCurrent().device:getCursor()
end

function tty.setCursor(dx, dy)
    return tty.getCurrent().device:setCursor(dx, dy)
end

function tty.write(str)
    tty.getCurrent().device:write(str)
end

function tty.print(str)
    tty.getCurrent().device:write(str .. "\n")
end

function tty.read(...)
    return tty.getCurrent():read(...)
end

---@type kernel_module
return {
    load = function() end,
    unload = function() end,
    module = tty,
    manifest = {
        name = "tty",
        desc = "tty driver",
        version_n = 1,
        version = "0.1.0-dev-OC"
    }
}
