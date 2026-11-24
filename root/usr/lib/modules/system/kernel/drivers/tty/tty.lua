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
local computer = require("computer")

---@type tty_driver[]
local ttys = {}
-- The tty the keyboard types into.
local activeId = 0

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
            system.printk("tty: failed to create vt: cannot load module: " .. e, "err")
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
-- ------------------------------------------------------------
-- Input layer. Key signals reach the tty in kernel context (an event hook,
-- see tty module load), whether or not anything is reading: the tty keeps
-- the key state, repeats held keys itself and queues one token per key
-- press (or repeat) for its readers. Readers block on the queue; what is
-- typed while nobody reads is kept for the next read (up to INPUT_LIMIT).
-- OC's own repeated key_down events only show that a key is still down.
-- ------------------------------------------------------------
local INPUT_LIMIT = 256
-- Modifier and lock keys never produce input.
local MODIFIERS = {
    [29] = true, [157] = true, -- control
    [42] = true, [54] = true,  -- shift
    [56] = true, [184] = true, -- alt
    [219] = true, [220] = true, -- meta
    [58] = true, [69] = true, [70] = true, -- caps, num, scroll lock
}
-- Repeat delay and rate from /boot/config.lua (key_repeat_delay in seconds,
-- key_repeat_rate per second). Rates above 20 (one per game tick) are met
-- by queuing more than one repeat in a tick.
local function repeatDelay()
    return tonumber(system.config and system.config.key_repeat_delay) or 0.35
end
local function repeatInterval()
    local rate = tonumber(system.config and system.config.key_repeat_rate) or 30
    return 1 / math.max(1, rate)
end
-- most repeats queued at once when the tty fell behind
local REPEAT_BURST = 4
-- Without OC repeat events for this long a held key is taken as released
-- (its key_up was lost, for example when the window lost focus).
local REPEAT_STALE = 1.0
-- Ctrl+C and Ctrl+D act once per press.
local NO_REPEAT_CHARS = { [3] = true, [4] = true }

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

-- The process currently blocked in or running a read, if it still exists.
function tty_driver:activeReader()
    local r = self.reader
    if not r then return nil end
    local proc = process.get(r.pid)
    if not proc or proc.instance ~= r.instance then
        self.reader = nil
        return nil
    end
    return r
end

-- Whether keyboard input is for this tty's readers. A process that made
-- itself the foreground (event.setForeground) to take key events directly
-- gets them alone; queuing them too would replay them at the next read.
function tty_driver:ownsInput()
    if self:activeReader() then return true end
    local last = self.lastReader
    return last == nil or event.getForeground() == last
end

-- Queues a token for readers and wakes them.
function tty_driver:push(token)
    local q = self.queue
    if #q >= INPUT_LIMIT then return end
    q[#q + 1] = token
    process.wakeIO(self.channel)
end

-- A signal from the keyboard (kernel context).
function tty_driver:signal(name, _, char, key)
    if name == "key_down" then
        if not key then return end
        local now = computer.uptime()
        if self.keys[key] then
            -- OC's repeat of a held key
            local held = self.held
            if held and held.key == key then held.seen = now end
            return
        end
        self.keys[key] = char or 0
        if MODIFIERS[key] then return end
        if not self:ownsInput() then
            self.held = nil
            return
        end
        if char == 3 and not self:activeReader() and self.flags.canonical then
            -- Ctrl+C while nobody reads: interrupt the foreground process
            -- and drop the pending input
            local proc = process.get(event.getForeground())
            if proc then table.insert(proc.signals, 2) end
            self.queue = {}
            self.held = nil
            return
        end
        if NO_REPEAT_CHARS[char] then
            self.held = nil
        else
            self.held = { key = key, char = char, due = now + repeatDelay(), seen = now }
        end
        self:push({ char = char, key = key })
    elseif name == "key_up" then
        if not key then return end
        self.keys[key] = nil
        local held = self.held
        if held and held.key == key then self.held = nil end
    elseif name == "clipboard" then
        self:push({ paste = tostring(char or "") })
    end
end

-- Repeats of the held key that are due (kernel thread, every pass).
function tty_driver:tickRepeat(now)
    local held = self.held
    -- uptime moves in 0.05 s ticks that do not add up exactly
    if not held or now + 1e-6 < held.due then return end
    if not self:ownsInput() then
        self.held = nil
        return
    end
    if now - held.seen > REPEAT_STALE then
        self.keys[held.key] = nil
        self.held = nil
        return
    end
    -- every repeat that fell due, keeping the schedule so the rate holds
    -- when passes are late
    local interval = repeatInterval()
    local n = math.floor((now - held.due) / interval + 1e-6) + 1
    held.due = held.due + n * interval
    if held.due <= now then held.due = now + interval end
    for _ = 1, math.min(n, REPEAT_BURST) do
        self:push({ char = held.char, key = held.key })
    end
end

-- Next queued token, blocking until there is one.
function tty_driver:nextToken()
    while true do
        local token = table.remove(self.queue, 1)
        if token then return token end
        self.device:setInputCursor(self.in_pid)
        process.blockIO(self.channel)
    end
end

-- One key press (or repeat) while reading.
function tty_driver:keyPress(char, key, canonical, mask, hint)
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
end

function tty_driver:paste(text, canonical, mask, hint)
    if canonical then
        -- paste into the line, up to the first line break
        text = text:gsub("\r", "")
        local first, rest = text:match("^([^\n]*)\n?(.*)$")
        self:insertText((first:gsub("[%c]", "")), mask)
        if text:find("\n") then
            self.reading = self:editKey(13, nil, mask, hint)
            if rest ~= "" then self.read_buffer = self.read_buffer .. rest end
        end
    else
        self.read_buffer = self.read_buffer .. text
        if not self.flags.disableWriteCharInput and not self.rawRead then
            self.device:write(mask or text)
        end
        self.reading = false
    end
end

-- Takes queued input until the current read has what it needs.
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
        local token = self:nextToken()
        if token.paste then
            self:paste(token.paste, canonical, mask, hint)
        else
            self:keyPress(token.char, token.key, canonical, mask, hint)
        end
        if self.reading then self.device:setInputCursor(self.in_pid) end
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
    local me = process.get(self.in_pid)
    self.reader = { pid = self.in_pid, instance = me and me.instance }
    self.lastReader = self.in_pid
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
    self.reader = nil
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
    dev.keys, dev.queue, dev.channel = {}, {}, {}
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
    activeId = id
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
    local t = tty.getCurrent()
    if not t then return false end
    for _, c in pairs(t.keys) do
        if c == char then return true end
    end
    return false
end

function tty.isKeyPressing(key)
    local t = tty.getCurrent()
    return t ~= nil and t.keys[key] ~= nil
end

-- Keyboard signals, from the kernel's event hook.
function tty.signal(ev)
    local t = ttys[activeId]
    if t then t:signal(ev[1], ev[2], ev[3], ev[4]) end
end

-- Due key repeats of every tty (kernel thread).
function tty.tick(now)
    now = now or computer.uptime()
    for _, t in pairs(ttys) do t:tickRepeat(now) end
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

local hookId

---@type kernel_module
return {
    load = function()
        -- keyboard input reaches the tty in kernel context, read or not
        hookId = event.addHook(tty.signal)
        system.createKernelThread(function()
            while true do
                tty.tick()
                coroutine.yield()
            end
        end, "tty_input", {})
    end,
    unload = function()
        if hookId then event.removeHook(hookId) end
    end,
    module = tty,
    manifest = {
        name = "tty",
        desc = "tty driver",
        version_n = 1,
        version = "0.1.0-dev-OC"
    }
}
