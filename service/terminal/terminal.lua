-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- terminal_service: text console on the display + keyboard input.
-- Installs the default stdin / stdout / stderr. Follows display hotplug:
-- when the GPU or screen disappears the console goes dark, and it is
-- redrawn from its row buffer once a display is available again.

local FG, BG, ERR_FG = 0xFFFFFF, 0x000000, 0xFF5555

---@type table
local gpu
local w, h = 80, 25
local cx, cy = 1, 1
local rows = {}
local cursor_on = false

local suspended = false

local function get_gpu()
    if suspended then return nil end
    if gpu and capability.is_valid(gpu) then return gpu end
    gpu = nil
    return nil
end

local function reset_rows()
    rows = {}
    for y = 1, h do rows[y] = "" end
end

local function draw_row(y)
    local g = get_gpu()
    if not g then return end
    g.fill(1, y, w, 1, " ")
    if rows[y] ~= "" then g.set(1, y, rows[y]) end
end

local function cursor(show)
    local g = get_gpu()
    if not g or cx > w then
        cursor_on = false
        return
    end
    local ch = rows[cy]:sub(cx, cx)
    if ch == "" then ch = " " end
    if show then
        g.set_bg(FG)
        g.set_fg(BG)
        g.set(cx, cy, ch)
        g.set_bg(BG)
        g.set_fg(FG)
    elseif cursor_on then
        g.set(cx, cy, ch)
    end
    cursor_on = show
end

local function scroll()
    table.remove(rows, 1)
    rows[h] = ""
    local g = get_gpu()
    if g then
        g.copy(1, 2, w, h - 1, 0, -1)
        g.fill(1, h, w, 1, " ")
    end
end

local function newline()
    cx = 1
    if cy >= h then scroll() else cy = cy + 1 end
end

local function put(text)
    while #text > 0 do
        if cx > w then newline() end
        local piece = text:sub(1, w - cx + 1)
        text = text:sub(#piece + 1)
        local row = rows[cy]
        if #row < cx - 1 then row = row .. string.rep(" ", cx - 1 - #row) end
        rows[cy] = row:sub(1, cx - 1) .. piece .. row:sub(cx + #piece)
        local g = get_gpu()
        if g then g.set(cx, cy, piece) end
        cx = cx + #piece
    end
end

local function acquire()
    local g = system.open("display")
    local s = system.open("screen")
    if not g or not s then return false end
    g.bind(s.addr())
    local old_rows, old_h = rows, h
    w, h = g.max_resolution()
    g.set_resolution(w, h)
    -- resolution may differ from the previous one: keep the newest rows
    reset_rows()
    local shift = math.max(0, #old_rows - h)
    for y = 1, math.min(#old_rows, h) do
        rows[y] = (old_rows[y + shift] or ""):sub(1, w)
    end
    cy = math.max(1, math.min(cy - shift, h))
    cx = math.min(cx, w)
    g.set_fg(FG)
    g.set_bg(BG)
    gpu = g
    return true
end

local function redraw()
    local g = get_gpu()
    if not g then return end
    g.set_fg(FG)
    g.set_bg(BG)
    g.fill(1, 1, w, h, " ")
    for y = 1, h do
        if rows[y] ~= "" then g.set(1, y, rows[y]) end
    end
end

-- ------------------------------------------------------------
--  term API
-- ------------------------------------------------------------

term = {}

function term.size()
    return w, h
end

function term.write(s)
    s = tostring(s):gsub("\t", "    "):gsub("\r", "")
    cursor(false)
    local pos = 1
    while pos <= #s do
        local nl = s:find("\n", pos, true)
        put(nl and s:sub(pos, nl - 1) or s:sub(pos))
        if nl then
            newline()
            pos = nl + 1
        else
            pos = #s + 1
        end
    end
end

function term.clear()
    reset_rows()
    cx, cy = 1, 1
    cursor_on = false
    redraw()
end

---Stop drawing (a compositor owns the screen); output is still tracked.
function term.suspend()
    suspended = true
    cursor_on = false
end

---Take the screen back and repaint.
function term.resume()
    suspended = false
    cursor_on = false
    if not get_gpu() then acquire() end
    redraw()
end

---Repaint the whole console (after a full-screen program used the display).
function term.redraw()
    cursor_on = false
    redraw()
end

function term.set_color(fg)
    local g = get_gpu()
    if g then g.set_fg(fg or FG) end
end

local history = {}
local HISTORY_MAX = 50

-- key codes (OC / LWJGL)
local K = { left = 203, right = 205, up = 200, down = 208, home = 199, end_ = 207, delete = 211, back = 14, enter = 28, tab = 15 }

local function is_input_event(ev)
    return ev.type == "key_down" or ev.type == "clipboard"
end

---Read one line with cursor editing, history (up/down) and optional tab
---completion. `complete(prefix)` returns a replacement for the text before the
---cursor, or nil. Returns "" on Ctrl+C and nil on Ctrl+D at an empty line.
local function read_line(complete)
    local buf, pos = "", 0
    local start_x, start_y = cx, cy
    local maxlen = w - start_x      -- keep one cell free for the cursor
    local hist_i, saved = #history + 1, ""

    local function render()
        cursor(false)
        local row = rows[start_y]
        if #row < start_x - 1 then row = row .. string.rep(" ", start_x - 1 - #row) end
        rows[start_y] = row:sub(1, start_x - 1) .. buf
        local g = get_gpu()
        if g then
            g.fill(start_x, start_y, w - start_x + 1, 1, " ")
            if #buf > 0 then g.set(start_x, start_y, buf) end
        end
        cx = start_x + pos
        cursor(true)
    end

    local function insert(text)
        text = text:gsub("[^\32-\126]", "")
        if text == "" then return end
        text = text:sub(1, maxlen - #buf)
        buf = buf:sub(1, pos) .. text .. buf:sub(pos + 1)
        pos = pos + #text
    end

    local function finish()
        cursor(false)
        cx = start_x + #buf
        newline()
    end

    render()
    while true do
        local ev = event.pull(nil, nil, is_input_event)
        if ev.type == "clipboard" then
            insert((tostring(ev.data[3] or ""):match("^[^\r\n]*")))
            render()
        else
            local char, code = ev.data[3], ev.data[4]
            if char == 13 or code == K.enter then
                finish()
                if buf ~= "" and history[#history] ~= buf then
                    history[#history + 1] = buf
                    if #history > HISTORY_MAX then table.remove(history, 1) end
                end
                return buf
            elseif char == 3 then                       -- Ctrl+C
                cursor(false)
                cx = start_x + #buf
                put("^C")
                newline()
                return ""
            elseif char == 4 and buf == "" then         -- Ctrl+D
                finish()
                return nil
            elseif char == 8 or code == K.back then
                if pos > 0 then
                    buf = buf:sub(1, pos - 1) .. buf:sub(pos + 1)
                    pos = pos - 1
                end
            elseif code == K.delete then
                buf = buf:sub(1, pos) .. buf:sub(pos + 2)
            elseif code == K.left then
                if pos > 0 then pos = pos - 1 end
            elseif code == K.right then
                if pos < #buf then pos = pos + 1 end
            elseif code == K.home or char == 1 then
                pos = 0
            elseif code == K.end_ or char == 5 then
                pos = #buf
            elseif char == 21 then                      -- Ctrl+U
                buf, pos = buf:sub(pos + 1), 0
            elseif code == K.up then
                if hist_i > 1 then
                    if hist_i == #history + 1 then saved = buf end
                    hist_i = hist_i - 1
                    buf = history[hist_i]:sub(1, maxlen)
                    pos = #buf
                end
            elseif code == K.down then
                if hist_i <= #history then
                    hist_i = hist_i + 1
                    buf = hist_i == #history + 1 and saved or history[hist_i]:sub(1, maxlen)
                    pos = #buf
                end
            elseif char == 9 or code == K.tab then
                if complete then
                    local ok, res = pcall(complete, buf:sub(1, pos))
                    if ok and res then
                        res = res:sub(1, maxlen)
                        buf = res .. buf:sub(pos + 1)
                        pos = #res
                    end
                end
            elseif char and char >= 32 and char < 127 then
                insert(string.char(char))
            end
            render()
        end
    end
end

---Read one line. While waiting, the calling process receives keyboard input.
function term.read_line(complete)
    local pid = process_manager.self()
    router.watch_input(pid)
    local ok, res = pcall(read_line, complete)
    router.unwatch_input(pid)
    if not ok then error(res, 0) end
    return res
end

-- ------------------------------------------------------------
--  Default standard streams
-- ------------------------------------------------------------

process_manager.default_stdout = {
    write = function(_, s)
        term.write(s)
        return true
    end,
}

process_manager.default_stderr = {
    write = function(_, s)
        term.set_color(ERR_FG)
        term.write(s)
        term.set_color(FG)
        return true
    end,
}

process_manager.default_stdin = {
    read = function(_, fmt)
        if fmt == nil then fmt = "l" end
        if type(fmt) == "string" then fmt = fmt:gsub("^%*", "") end
        if fmt == "l" or fmt == "L" then
            local line = term.read_line()
            if line and fmt == "L" then line = line .. "\n" end
            return line
        end
        error("stdin supports only 'l' / 'L' reads", 2)
    end,
}

-- ------------------------------------------------------------
--  Start
-- ------------------------------------------------------------

reset_rows()
if acquire() then
    cx, cy = 1, 1
    reset_rows()
    log.screen = false   -- from here on the terminal owns the screen
    log.info("[terminal] display %dx%d acquired, log is file-only now", w, h)
    redraw()
    term.write(_DISTRO .. " " .. _VERSION .. "\n")
else
    log.warn("[terminal] no display available yet")
end
service_manager.ready("terminal")

while true do
    local ev = event.pull()
    if ev.type == "device_removed" and (ev.nexus_type == "display" or ev.nexus_type == "screen") then
        gpu = nil
        log.screen = false
        log.info("[terminal] lost %s %s", ev.nexus_type, ev.addr:sub(1, 8))
    elseif ev.type == "device_added" and (ev.nexus_type == "display" or ev.nexus_type == "screen") then
        if not get_gpu() and acquire() then
            redraw()
            log.info("[terminal] display re-acquired")
        end
    end
end
