---@type devfs
local devfs = require("devfs")
---@type module
local module = require("module")
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
    self.device = vt.new(self.id)
end

-- OpenComputers key codes used by the line editor and raw mode.
local KEY_BACK, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT = 14, 200, 208, 203, 205
local KEY_HOME, KEY_END, KEY_DELETE, KEY_PGUP, KEY_PGDN = 199, 207, 211, 201, 209
local KEY_INSERT = 210
-- Keys that repeat while held (OC resends key_down without key_up).
local REPEATABLE = {
    [KEY_BACK] = true, [KEY_UP] = true, [KEY_DOWN] = true, [KEY_LEFT] = true, [KEY_RIGHT] = true,
    [KEY_HOME] = true, [KEY_END] = true, [KEY_DELETE] = true, [KEY_PGUP] = true, [KEY_PGDN] = true,
}
-- Raw mode: special keys arrive as the usual terminal escape sequences.
local RAW_SEQUENCES = {
    [KEY_UP] = "\27[A", [KEY_DOWN] = "\27[B", [KEY_RIGHT] = "\27[C", [KEY_LEFT] = "\27[D",
    [KEY_HOME] = "\27[H", [KEY_END] = "\27[F", [KEY_INSERT] = "\27[2~", [KEY_DELETE] = "\27[3~",
    [KEY_PGUP] = "\27[5~", [KEY_PGDN] = "\27[6~",
}
local HISTORY_LIMIT = 200

-- ------------------------------------------------------------
-- Line editor. The input occupies the end of the VT buffer, starting at
-- column self.startx of the row where reading began; vt wraps it every
-- `width` columns, so positions follow from plain arithmetic.
-- ------------------------------------------------------------

function tty_driver:canEdit()
    local dev = self.device
    return dev and dev.buf and dev.width and dev.setCursor and not self.flags.disableWriteCharInput
end

-- VT cursor position of input index p (0 = before the first character).
function tty_driver:inputPosition(p)
    local dev = self.device
    local w = dev.width
    local endOff = self.startx - 1 + #self.buffer
    local off = self.startx - 1 + p
    return off % w + 1, #dev.buf - (endOff // w - off // w)
end

function tty_driver:placeCursor()
    if not self:canEdit() then return end
    self.device:setCursor(self:inputPosition(self.pos))
end

function tty_driver:toInputEnd()
    if not self:canEdit() then return end
    self.device:setCursor(self:inputPosition(#self.buffer))
end

local function shown(text, mask)
    return mask and string.rep(mask, #text) or text
end

-- Replaces the input with `text` and puts the cursor at `pos`.
function tty_driver:setInput(text, pos, mask)
    local dev = self.device
    local echo = self:canEdit()
    if echo then
        self:toInputEnd()
        local wraps = (self.startx - 1 + #self.buffer) // dev.width
        local erase = #self.buffer + wraps
        if erase > 0 then dev:backspace(erase) end
    end
    self.buffer, self.pos = text, pos
    if echo then
        if #text > 0 then dev:write(shown(text, mask)) end
        self:placeCursor()
    end
end

function tty_driver:insertText(text, mask)
    if text == "" then return end
    local buffer, pos = self.buffer, self.pos
    if pos == #buffer then
        -- appending: no need to redraw what is already shown
        local echo = self.device and not self.flags.disableWriteCharInput
        if self:canEdit() then self:toInputEnd() end
        self.buffer = buffer .. text
        self.pos = #self.buffer
        if echo then self.device:write(shown(text, mask)) end
    else
        self:setInput(buffer:sub(1, pos) .. text .. buffer:sub(pos + 1), pos + #text, mask)
    end
end

-- Expand the word before the cursor to the longest common prefix of the
-- hints returned by the reader's completion callback.
function tty_driver:complete(hint, mask)
    if not hint or not self.device then return end
    local before = self.buffer:sub(1, self.pos)
    local ok, hints = pcall(hint, before, #before + 1)
    if not ok or type(hints) ~= "table" then return end

    local completion
    for _, candidate in ipairs(hints) do
        if type(candidate) == "string" and candidate ~= "" then
            if not completion then
                completion = candidate
            else
                local limit = math.min(#completion, #candidate)
                local i = 1
                while i <= limit and completion:sub(i, i) == candidate:sub(i, i) do
                    i = i + 1
                end
                completion = completion:sub(1, i - 1)
            end
        end
    end

    if not completion or #completion <= #before then return end
    if completion:sub(1, #before) ~= before then return end
    self:insertText(completion:sub(#before + 1), mask)
end

function tty_driver:historyMove(delta, mask)
    local history = self.history
    if not history or #history == 0 then return end
    local index = self.historyIndex
    if not index then
        if delta > 0 then return end
        self.historyDraft = self.buffer
        index = #history + 1
    end
    index = index + delta
    if index < 1 then index = 1 end
    if index > #history then
        self.historyIndex = nil
        local draft = self.historyDraft or ""
        self:setInput(draft, #draft, mask)
        return
    end
    self.historyIndex = index
    local entry = history[index]
    self:setInput(entry, #entry, mask)
end

function tty_driver:remember(line, mask)
    local history = self.history
    if not history or mask or line == "" or not line:find("%S") then return end
    if history[#history] ~= line then table.insert(history, line) end
    while #history > (self.historyLimit or HISTORY_LIMIT) do table.remove(history, 1) end
end

-- Handles one key in canonical mode; returns false when the line is done.
function tty_driver:editKey(char, key, mask, hint)
    local buffer, pos = self.buffer, self.pos
    if char == 13 then
        self:toInputEnd()
        self:remember(buffer, mask)
        self.read_buffer = self.read_buffer .. buffer .. "\n"
        self.buffer, self.pos = "", 0
        self.device:write("\n")
        return false
    elseif char == 3 then
        -- Ctrl+C (SIGINT)
        self:toInputEnd()
        local proc = process.get(self.in_pid)
        if proc then table.insert(proc.signals, 2) end
        self.buffer, self.pos, self.read_buffer = "", 0, ""
        return false
    elseif char == 4 then
        -- Ctrl+D: EOF on an empty line, otherwise hand over what was typed
        self:toInputEnd()
        if #buffer > 0 then
            self.read_buffer = self.read_buffer .. buffer
            self.buffer, self.pos = "", 0
        else
            self.eof = true
        end
        return false
    elseif char == 9 then
        self:complete(hint, mask)
    elseif char == 8 or key == KEY_BACK then
        if pos > 0 then self:setInput(buffer:sub(1, pos - 1) .. buffer:sub(pos + 1), pos - 1, mask) end
    elseif key == KEY_DELETE then
        if pos < #buffer then self:setInput(buffer:sub(1, pos) .. buffer:sub(pos + 2), pos, mask) end
    elseif key == KEY_LEFT then
        if pos > 0 then self.pos = pos - 1; self:placeCursor() end
    elseif key == KEY_RIGHT then
        if pos < #buffer then self.pos = pos + 1; self:placeCursor() end
    elseif key == KEY_HOME or char == 1 then
        self.pos = 0; self:placeCursor()
    elseif key == KEY_END or char == 5 then
        self.pos = #buffer; self:placeCursor()
    elseif key == KEY_UP then
        self:historyMove(-1, mask)
    elseif key == KEY_DOWN then
        self:historyMove(1, mask)
    elseif char == 21 then
        -- Ctrl+U: delete up to the cursor
        self:setInput(buffer:sub(pos + 1), 0, mask)
    elseif char == 23 then
        -- Ctrl+W: delete the word before the cursor
        local before = buffer:sub(1, pos):gsub("%S*%s*$", "")
        self:setInput(before .. buffer:sub(pos + 1), #before, mask)
    elseif char and char >= 32 and char <= 126 then
        self:insertText(string.char(char), mask)
    end
    return true
end

function tty_driver:read_pump(mask, hint)
    self.reading = true
    local canonical = self.flags.canonical and not self.rawRead
    if canonical and self:canEdit() then
        -- where the input starts: the cursor, minus what is already typed
        local w = self.device.width
        self.pos = #self.buffer
        self.startx = (self.device.cx - 1 - #self.buffer) % w + 1
    end
    self.device:setInputCursor(self.in_pid)
    while self.reading do
        local ev = { event.pull() }
        local etype = ev[1]
        local char = ev[3]
        local key = ev[4]

        if etype == "key_down" then
            local repeating = self.pressing[key] and (self.rawRead or REPEATABLE[key])
            if not self.pressing[key] or repeating then
                self.pressing[key] = true
                if char then self.pressingChars[char] = true end

                if canonical then
                    self.reading = self:editKey(char, key, mask, hint)
                elseif self.rawRead and (not char or char == 0) and RAW_SEQUENCES[key] then
                    self.read_buffer = self.read_buffer .. RAW_SEQUENCES[key]
                    self.reading = false
                elseif self.rawRead and char == 27 then
                    -- a lone Esc, distinct from the start of a sequence
                    self.read_buffer = self.read_buffer .. "\27\27"
                    self.reading = false
                elseif char and char ~= 0 then
                    self.read_buffer = self.read_buffer .. utf8.char(char)
                    self.reading = false
                end
                if self.reading then self.device:setInputCursor(self.in_pid) end
            end
        elseif etype == "key_up" then
            self.pressing[key] = false
            if char then self.pressingChars[char] = false end
        elseif etype == "clipboard" then
            if canonical then
                -- paste into the line, up to the first line break
                local text = tostring(char or ""):gsub("\r", "")
                local first, rest = text:match("^([^\n]*)\n?(.*)$")
                self:insertText((first:gsub("[%c]", "")), mask)
                if text:find("\n") then
                    self.reading = self:editKey(13, nil, mask, hint)
                    if rest ~= "" then self.read_buffer = self.read_buffer .. rest end
                end
            else
                self.read_buffer = self.read_buffer .. char
                if not self.flags.disableWriteCharInput and not self.rawRead then
                    self.device:write(mask or char)
                end
                self.reading = false
            end
        end
    end
    self.device:setInputCursor(nil)
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

function tty_driver:readLine(chop, mask, hint)
    while not self.read_buffer:find("\n") do
        if self.eof then break end
        self:read_pump(mask, hint)
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

    local formats = table.pack(...)
    -- A trailing options table ({ complete = fn, history = list, raw = bool })
    -- or a trailing completion function are not formats.
    local options
    if formats.n > 0 and type(formats[formats.n]) == "table" then
        options = formats[formats.n]
        formats[formats.n] = nil
        formats.n = formats.n - 1
    end
    local hint = options and options.complete
    if formats.n > 0 and type(formats[formats.n]) == "function" then
        hint = formats[formats.n]
        formats[formats.n] = nil
        formats.n = formats.n - 1
    end
    self.history = options and type(options.history) == "table" and options.history or nil
    self.historyLimit = options and tonumber(options.historyLimit) or nil
    self.historyIndex, self.historyDraft = nil, nil
    self.rawRead = options and options.raw and true or false
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
            res = self:readLine(true, mask, hint)
        else
            local mode = fmt:gsub("^%*", "")
            if mode == "n" then
                res = self:readNumber(mask)
            elseif mode == "l" then
                res = self:readLine(true, mask, hint)
            elseif mode == "L" then
                res = self:readLine(false, mask, hint)
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
    self.history, self.rawRead = nil, false
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

function tty_driver:clear()
    self.device:clear()
end

---@class module_tty
local tty = {}

function tty.new(id)
    local dev = setmetatable({}, {__index = tty_driver})
    dev.id = id
    dev:init()
    local callbacks = {
        read = function(_handle, ...)
            if not dev.device then return nil, "TTY detached" end
            return dev:read(...)
        end,
        write = function(_handle, value)
            if not dev.device then return false, "TTY detached" end
            dev:write(value)
            return true
        end,
    }
    devfs.create("tty" .. tostring(id), callbacks)
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
