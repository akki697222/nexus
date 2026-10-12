-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- gui-term: terminal emulator window. Runs the shell with its standard
-- streams bound to a compositor surface (text output, line editing with
-- history and tab completion, Ctrl+C / Ctrl+D).
local gui      = require("gui")
local lineedit = require("lineedit")

local conn = gui.connect()
local win, W, H = gui.window(conn, "Terminal", 78, 24)

local FG, BG, ERR_FG = 0xE6E6E6, 0x101418, 0xFF7070
local CURSOR_FG, CURSOR_BG = 0x101418, 0xE6E6E6

local SCROLLBACK_MAX = 500
local scrollback = {}            -- lines that scrolled off the top
local view_off = 0               -- > 0: showing history, this many lines above the live view
local rows = {}                  -- plain text of every line (kept for resize)
local cx, cy = 1, 1             -- output cursor
local history = {}
local reader                     -- { pid, ed, sx, sy } while a process waits for a line
local shell_pid
local term_id = tostring({}):gsub("[^%w]", "")

local function reset_rows()
    rows = {}
    for y = 1, H do rows[y] = "" end
end

local function redraw_all()
    win.colors(FG, BG)
    win.clear(BG)
    for y = 1, H do
        if rows[y] ~= "" then win.set(1, y, rows[y], FG, BG) end
    end
end

local function newline()
    cx = 1
    if cy >= H then
        win.scroll(1)
        scrollback[#scrollback + 1] = table.remove(rows, 1)
        if #scrollback > SCROLLBACK_MAX then table.remove(scrollback, 1) end
        rows[H] = ""
    else
        cy = cy + 1
    end
end

local function put(text, fg)
    text = text:gsub("\t", "    "):gsub("\r", ""):gsub("%c", "")
    while #text > 0 do
        if cx > W then newline() end
        local piece = text:sub(1, W - cx + 1)
        text = text:sub(#piece + 1)
        local row = rows[cy]
        if #row < cx - 1 then row = row .. string.rep(" ", cx - 1 - #row) end
        rows[cy] = row:sub(1, cx - 1) .. piece .. row:sub(cx + #piece)
        win.set(cx, cy, piece, fg, BG)
        cx = cx + #piece
    end
end

-- show history: `view_off` lines above the live screen
local function show_scrolled()
    local base = #scrollback
    win.colors(FG, BG)
    win.clear(BG)
    for y = 1, H do
        local i = base - view_off + y
        local line = i <= base and scrollback[i] or rows[i - base]
        if line and line ~= "" then win.set(1, y, line:sub(1, W), FG, BG) end
    end
    win.set(W - 8, 1, " scroll ", 0x101418, 0xD8B24A)
    win.commit()
end

local function snap_to_bottom()
    if view_off > 0 then
        view_off = 0
        redraw_all()
    end
end

local function scroll_view(delta)
    local n = math.max(0, math.min(#scrollback, view_off + delta))
    if n == view_off then return end
    local was_live = view_off == 0
    view_off = n
    if view_off == 0 then
        redraw_all()
        win.commit()
    else
        show_scrolled()
    end
end

local function write_text(s, fg)
    snap_to_bottom()
    s = tostring(s)
    local pos = 1
    while pos <= #s do
        local nl = s:find("\n", pos, true)
        put(nl and s:sub(pos, nl - 1) or s:sub(pos), fg)
        if nl then
            newline()
            pos = nl + 1
        else
            pos = #s + 1
        end
    end
end

-- draw the line being edited (and the cursor block)
local function render_input(no_cursor)
    if not reader then return end
    local ed = reader.ed
    win.fill(reader.sx, reader.sy, W - reader.sx + 1, 1, " ", FG, BG)
    if #ed.buf > 0 then win.set(reader.sx, reader.sy, ed.buf, FG, BG) end
    local at = reader.sx + ed.pos
    if not no_cursor and at <= W then
        local ch = ed.buf:sub(ed.pos + 1, ed.pos + 1)
        win.set(at, reader.sy, ch == "" and " " or ch, CURSOR_FG, CURSOR_BG)
    end
    rows[reader.sy] = (rows[reader.sy] or ""):sub(1, reader.sx - 1) .. ed.buf
end

local function flush()
    if view_off > 0 then
        win.commit()
        return
    end
    render_input()
    win.commit()
end

-- ------------------------------------------------------------
--  Standard streams handed to the shell
-- ------------------------------------------------------------

local function read_line(complete)
    local sx, sy = cx, cy
    reader = {
        pid = process_manager.self(),
        sx = sx, sy = sy,
        ed = lineedit.new{ maxlen = math.max(1, W - sx - 1), history = history, complete = complete },
    }
    flush()
    local ev = event.pull("wterm_line", nil, function(e) return e.term == term_id end)
    reader = nil
    if ev.eof then return nil end
    return ev.line
end

local stdin_stream = {
    read = function(_, fmt, complete)
        if fmt == nil then fmt = "l" end
        if type(fmt) == "string" then fmt = fmt:gsub("^%*", "") end
        if fmt == "l" or fmt == "L" then
            local line = read_line(complete)
            if line and fmt == "L" then line = line .. "\n" end
            return line
        elseif fmt == "a" then
            local parts = {}
            while true do
                local line = read_line(nil)
                if line == nil then break end
                parts[#parts + 1] = line .. "\n"
            end
            return table.concat(parts)
        end
        error("stdin supports 'l', 'L' and 'a' reads", 2)
    end,
}

local stdout_stream = {
    write = function(_, s)
        write_text(s, FG)
        flush()
        return true
    end,
}

local stderr_stream = {
    write = function(_, s)
        write_text(s, ERR_FG)
        flush()
        return true
    end,
}

-- ------------------------------------------------------------
--  Input handling
-- ------------------------------------------------------------

local function finish_line(result, line)
    local r = reader
    if result == "enter" then
        r.ed.pos = #r.ed.buf
        render_input(true)                  -- final text, cursor block removed
        cx, cy = r.sx + #r.ed.buf, r.sy
        newline()
        router.push_to(r.pid, { type = "wterm_line", term = term_id, line = r.ed.buf })
    elseif result == "eof" then
        render_input(true)
        cx, cy = r.sx, r.sy
        newline()
        router.push_to(r.pid, { type = "wterm_line", term = term_id, eof = true })
    end
    reader = nil
    win.commit()
end

local function send_interrupt()
    -- the shell waits for Ctrl+C while a foreground command runs
    router.push_to(shell_pid, { type = "key_down", data = { "key_down", "kbd", 3, 46, "player" } })
end

local function on_key(ev)
    if not ev.down then return end
    if ev.code == 201 or ev.code == 209 then                              -- PgUp / PgDn (with or without Shift)
        log.debug("[gui-term] page key code=%s off=%d back=%d", tostring(ev.code), view_off, #scrollback)
        scroll_view(ev.code == 201 and (H - 1) or -(H - 1))
        return
    end
    if ev.char ~= 0 or (ev.code ~= 42 and ev.code ~= 54 and ev.code ~= 29 and ev.code ~= 157
        and ev.code ~= 56 and ev.code ~= 184) then
        snap_to_bottom()                                                  -- any real key returns to live view
    end
    local r = reader
    if ev.char == 3 or (ev.ctrl and ev.code == 46) then               -- Ctrl+C
        if r and r.pid == shell_pid then
            write_text("^C\n", FG)
            r.ed.buf = ""
            finish_line("enter")
            return
        end
        send_interrupt()      -- the shell prints "^C" and kills the foreground command
        flush()
        return
    end
    if not r then return end
    local res = r.ed:key(ev.char, ev.code)
    if res then finish_line(res) else flush() end
end

local function on_paste(ev)
    if reader then
        reader.ed:insert((tostring(ev.text or ""):match("^[^\r\n]*")))
        flush()
    end
end

local function on_configure(ev)
    local nw, nh = ev.w, ev.h
    if nw == W and nh == H then return end
    view_off = 0
    local drop = math.max(0, #rows - nh)
    for _ = 1, drop do table.remove(rows, 1) end
    for y = #rows + 1, nh do rows[y] = "" end
    for y = 1, nh do rows[y] = rows[y]:sub(1, nw) end
    W, H = nw, nh
    cy = math.max(1, math.min(cy - drop, H))
    cx = math.min(cx, W)
    if reader then
        reader.sy = math.max(1, math.min(reader.sy - drop, H))
        reader.ed.maxlen = math.max(1, W - reader.sx - 1)
    end
    redraw_all()
    flush()
end

-- ------------------------------------------------------------
--  Start the shell
-- ------------------------------------------------------------

reset_rows()
redraw_all()
write_text("Nexus terminal\n", 0x808890)
win.commit()

shell_pid = process_manager.spawn({
    path   = "System://Exec/sh.lua",
    env    = { PATH = "System://Exec" },
    stdin  = stdin_stream,
    stdout = stdout_stream,
    stderr = stderr_stream,
})

while true do
    local ev = event.pull()
    if ev.type == "gui" then
        local k = ev.kind
        if k == "key" then on_key(ev)
        elseif k == "paste" then on_paste(ev)
        elseif k == "configure" then on_configure(ev)
        elseif k == "close" then break
        elseif k == "pointer" then
            if ev.action == "scroll" then
                log.debug("[gui-term] wheel dir=%s off=%d back=%d", tostring(ev.dir), view_off, #scrollback)
                scroll_view((ev.dir or 0) * 3)
            end
        elseif k == "focus" or k == "frame" then flush()
        end
    elseif ev.type == "process_died" then
        if ev.pid == shell_pid then
            shell_pid = nil
            break
        elseif reader and reader.pid == ev.pid then
            render_input(true)              -- reader died: drop its cursor block
            reader = nil
            win.commit()
        end
    end
end

if shell_pid and process_manager.get(shell_pid) then
    process_manager.kill(shell_pid)
end
win.destroy()
