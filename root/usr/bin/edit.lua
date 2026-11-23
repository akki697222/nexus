-- edit - a small full-screen text editor (in the spirit of OpenOS edit)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   edit [-r] <file>
--
--   arrows, Home/End, PgUp/PgDn   move
--   Ctrl+S save   Ctrl+W close   Ctrl+K cut line   Ctrl+U paste line
--   Ctrl+F find (again: next match)   Ctrl+G go to line
--
-- Draws on the terminal's alternate screen with ANSI sequences and reads
-- keys in raw mode, so it needs nothing beyond the tty.

local fs = require("filesystem")

local args = { ... }
local readonly, path = false, nil
for _, a in ipairs(args) do
    if a == "-r" then readonly = true elseif not path then path = a end
end
if not path then
    io.stderr:write("usage: edit [-r] <file>\n")
    return 1
end
if not io.isatty(0) or not io.isatty(1) then
    io.stderr:write("edit: needs a terminal\n")
    return 1
end
if path:sub(1, 1) ~= "/" then
    path = fs.concat(require("process").cwd() or "/", path)
end

-- Screen size from the GPU (queries are open to userland).
local width, height = 80, 25
do
    local comp = rawget(_ENV, "component") or select(2, pcall(require, "component"))
    if type(comp) == "table" and comp.list then
        local ok, w, h = pcall(function()
            local gpu = comp.proxy(comp.list("gpu")())
            return gpu.getViewport()
        end)
        if ok and tonumber(w) and tonumber(h) then width, height = w, h end
    end
end
local textRows = height - 1

-- Buffer ------------------------------------------------------------------

local lines, trailingNewline = { "" }, true
local isNew = not fs.exists(path)
if not isNew then
    if fs.isDirectory(path) then
        io.stderr:write("edit: " .. path .. ": is a directory\n")
        return 1
    end
    local f, err = fs.open(path, "r")
    if not f then
        io.stderr:write("edit: " .. path .. ": " .. tostring(err) .. "\n")
        return 1
    end
    local data = f:read("*a") or ""
    f:close()
    lines = {}
    data = data:gsub("\r\n", "\n")
    trailingNewline = data == "" or data:sub(-1) == "\n"
    for line in (trailingNewline and data or data .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines[1] = "" end
end

local cx, cy = 1, 1        -- cursor: column (1..#line+1) and line
local top, left = 1, 1     -- first visible line and column
local modified = false
local message = isNew and "New file" or nil
local clipboard = {}
local cutting = false      -- consecutive ^K append to the clipboard
local closeArmed = false
local lastSearch

-- Terminal ----------------------------------------------------------------

local out = {}
local function emit(s) out[#out + 1] = s end
local function flush()
    io.write(table.concat(out))
    out = {}
end

-- One key: a byte, or a whole escape sequence. The tty sends a lone Esc
-- as ESC ESC, so a sequence never has to be told apart by timing.
local function readKey()
    local c = io.read(1, { raw = true })
    if c ~= "\27" then return c end
    local b = io.read(1, { raw = true })
    if b ~= "[" then return "\27" end
    local t = io.read(1, { raw = true }) or ""
    if t:match("%d") then t = t .. (io.read(1, { raw = true }) or "") end
    return "\27[" .. t
end

local function display(line)
    return (line:gsub("\t", " "))
end

local function status()
    local name = path:match("[^/]+$") or path
    local left_ = string.format(" %s%s%s", name, modified and " [+]" or "", readonly and " [ro]" or "")
    local right = string.format("Ln %d, Col %d ", cy, cx)
    -- a message takes the place of the file name and the key help
    local text = message and (" " .. message)
        or (left_ .. "  ^S Save  ^W Close  ^K Cut  ^U Paste  ^F Find  ^G Line")
    local room = width - #right
    if #text > room then text = text:sub(1, room) end
    return text .. string.rep(" ", room - #text) .. right
end

local function scrollToCursor()
    if cy < top then top = cy end
    if cy >= top + textRows then top = cy - textRows + 1 end
    if cx < left then left = cx end
    if cx >= left + width then left = cx - width + 1 end
end

local function redraw()
    scrollToCursor()
    for row = 1, textRows do
        local line = lines[top + row - 1]
        emit(string.format("\27[%d;1H", row))
        if line then emit(display(line):sub(left, left + width - 1)) end
        emit("\27[K")
    end
    emit(string.format("\27[%d;1H\27[7m%s\27[0m", height, status():sub(1, width - 1)))
    emit(string.format("\27[%d;%dH", cy - top + 1, cx - left + 1))
    flush()
end

-- Prompt on the status line; returns the text or nil on Esc / Ctrl+C.
local function prompt(label, initial)
    local text = initial or ""
    while true do
        emit(string.format("\27[%d;1H\27[7m%s\27[K", height,
            (" " .. label .. text):sub(1, width - 1)))
        emit("\27[0m")
        flush()
        local key = readKey()
        if key == "\r" or key == "\n" then return text
        elseif key == "\27" or key == "\3" then return nil
        elseif key == "\8" then text = text:sub(1, -2)
        elseif #key == 1 and key:byte() >= 32 and key:byte() <= 126 then text = text .. key
        end
    end
end

-- Editing -----------------------------------------------------------------

local function clampX() cx = math.max(1, math.min(cx, #lines[cy] + 1)) end

local function save()
    if readonly then message = "Read-only"; return false end
    local f, err = fs.open(path, "w")
    if not f then message = "Cannot save: " .. tostring(err); return false end
    local ok, werr = pcall(function()
        f:write(table.concat(lines, "\n") .. (trailingNewline and "\n" or ""))
    end)
    f:close()
    if not ok then message = "Cannot save: " .. tostring(werr); return false end
    modified, isNew = false, false
    message = string.format("Saved %d lines", #lines)
    return true
end

local function edited()
    modified = true
end

local function find(term)
    if not term or term == "" then return end
    lastSearch = term
    for i = 0, #lines do
        local ln = (cy - 1 + i) % #lines + 1
        local from = (i == 0) and cx + 1 or 1
        local s = lines[ln]:find(term, from, true)
        if s then
            cy, cx = ln, s
            message = nil
            return
        end
    end
    message = "Not found: " .. term
end

local actions = {}
actions["\27[A"] = function() if cy > 1 then cy = cy - 1; clampX() end end
actions["\27[B"] = function() if cy < #lines then cy = cy + 1; clampX() end end
actions["\27[D"] = function()
    if cx > 1 then cx = cx - 1 elseif cy > 1 then cy = cy - 1; cx = #lines[cy] + 1 end
end
actions["\27[C"] = function()
    if cx <= #lines[cy] then cx = cx + 1 elseif cy < #lines then cy = cy + 1; cx = 1 end
end
actions["\27[H"] = function() cx = 1 end
actions["\27[F"] = function() cx = #lines[cy] + 1 end
actions["\27[5~"] = function() cy = math.max(1, cy - textRows); clampX() end
actions["\27[6~"] = function() cy = math.min(#lines, cy + textRows); clampX() end
actions["\27[3~"] = function()
    if readonly then return end
    local line = lines[cy]
    if cx <= #line then
        lines[cy] = line:sub(1, cx - 1) .. line:sub(cx + 1); edited()
    elseif cy < #lines then
        lines[cy] = line .. table.remove(lines, cy + 1); edited()
    end
end
actions["\8"] = function()
    if readonly then return end
    if cx > 1 then
        local line = lines[cy]
        lines[cy] = line:sub(1, cx - 2) .. line:sub(cx); cx = cx - 1; edited()
    elseif cy > 1 then
        cx = #lines[cy - 1] + 1
        lines[cy - 1] = lines[cy - 1] .. table.remove(lines, cy); cy = cy - 1; edited()
    end
end
actions["\r"] = function()
    if readonly then return end
    local line = lines[cy]
    local indent = line:match("^[ \t]*"):sub(1, cx - 1)
    lines[cy] = line:sub(1, cx - 1)
    table.insert(lines, cy + 1, indent .. line:sub(cx))
    cy, cx = cy + 1, #indent + 1
    edited()
end
actions["\n"] = actions["\r"]
actions["\19"] = function() save() end -- ^S
actions["\11"] = function() -- ^K
    if readonly then return end
    if not cutting then clipboard = {} end
    clipboard[#clipboard + 1] = lines[cy]
    if #lines > 1 then table.remove(lines, cy) else lines[1] = "" end
    if cy > #lines then cy = #lines end
    cx = 1
    edited()
    message = string.format("Cut %d line%s", #clipboard, #clipboard == 1 and "" or "s")
end
actions["\21"] = function() -- ^U
    if readonly or #clipboard == 0 then return end
    for i, line in ipairs(clipboard) do table.insert(lines, cy + i - 1, line) end
    cy = cy + #clipboard
    if cy > #lines then cy = #lines end
    cx = 1
    edited()
end
actions["\6"] = function() -- ^F
    local term = prompt("Find: ", lastSearch)
    if term then find(term) else message = nil end
end
actions["\7"] = function() -- ^G
    local n = tonumber(prompt("Line: ") or "")
    if n then cy = math.max(1, math.min(#lines, math.floor(n))); cx = 1 end
    message = nil
end

-- Main loop ---------------------------------------------------------------

io.write("\27[?1049h\27[2J")
local ok, err = pcall(function()
    while true do
        redraw()
        local key = readKey()
        if key == nil then break end
        local wasCutting = key == "\11"
        if key ~= "\23" then closeArmed = false end
        if key ~= "\19" and key ~= "\11" then message = nil end
        if key == "\23" then -- ^W
            if not modified or closeArmed then break end
            closeArmed = true
            message = "Unsaved! ^S save, ^W discard"
        elseif actions[key] then
            actions[key]()
        elseif key == "\t" or (#key == 1 and key:byte() >= 32 and key:byte() <= 126) then
            if not readonly then
                local line = lines[cy]
                lines[cy] = line:sub(1, cx - 1) .. key .. line:sub(cx)
                cx = cx + 1
                edited()
            end
        end
        cutting = wasCutting
    end
end)
io.write("\27[?1049l")
if not ok then
    io.stderr:write("edit: " .. tostring(err) .. "\n")
    return 1
end
return 0
