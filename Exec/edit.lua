-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- edit <file>: small full-screen text editor.
--   arrows / Home / End / PgUp / PgDn  move      Ctrl+S  save
--   Backspace / Delete / Enter / Tab   edit      Ctrl+Q  quit (twice if unsaved)
local proc = process_manager.current_proc()
local path = proc.args[1]
if not path then
    stderr:write("usage: edit <file>\n")
    process_manager.exit(1)
end

local lines, modified = { "" }, false
if fs.exists(path) then
    local data, err = fs.read_file(path)
    if not data then
        stderr:write("edit: " .. tostring(err) .. "\n")
        process_manager.exit(1)
    end
    data = data:gsub("\r", ""):gsub("\t", "    ")
    lines = {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
end

local gpu = system.open("display")
if not gpu then
    stderr:write("edit: no display\n")
    process_manager.exit(1)
end
local W, H = gpu.resolution()
local VIEW = H - 1                    -- text rows; the last row is the status bar
local FG, BG = 0xFFFFFF, 0x000000

local cy, cx = 1, 1                   -- cursor line / column (1-based)
local top, left = 1, 0                -- first visible line / hidden columns
local message, quit_armed = "", false

local function clamp()
    if cy < 1 then cy = 1 end
    if cy > #lines then cy = #lines end
    if cx < 1 then cx = 1 end
    if cx > #lines[cy] + 1 then cx = #lines[cy] + 1 end
end

-- returns true if the view scrolled (full redraw needed)
local function scroll_into_view()
    local old_top, old_left = top, left
    if cy < top then top = cy end
    if cy >= top + VIEW then top = cy - VIEW + 1 end
    if cx <= left then left = cx - 1 end
    if cx > left + W then left = cx - W end
    return top ~= old_top or left ~= old_left
end

local function draw_line(sy)
    local idx = top + sy - 1
    local text = lines[idx]
    if text then
        local vis = text:sub(left + 1, left + W)
        gpu.set(1, sy, vis .. string.rep(" ", W - #vis))
    else
        gpu.set(1, sy, "~" .. string.rep(" ", W - 1))
    end
end

local function draw_status()
    local left_s = path .. (modified and " [+]" or "") .. (message ~= "" and ("  " .. message) or "")
    local right_s = string.format("Ln %d/%d Col %d", cy, #lines, cx)
    local pad = W - #left_s - #right_s
    local bar = pad > 0 and (left_s .. string.rep(" ", pad) .. right_s) or (left_s .. " "):sub(1, W)
    gpu.set_bg(FG)
    gpu.set_fg(BG)
    gpu.set(1, H, bar:sub(1, W) .. string.rep(" ", W - #bar))
    gpu.set_bg(BG)
    gpu.set_fg(FG)
end

local shown_sy                   -- screen row where the cursor block is currently drawn

local function draw_cursor(show)
    local sy = cy - top + 1
    local sx = cx - left
    local ch = (lines[cy] or ""):sub(cx, cx)
    if ch == "" then ch = " " end
    if show then
        gpu.set_bg(FG)
        gpu.set_fg(BG)
        gpu.set(sx, sy, ch)
        gpu.set_bg(BG)
        gpu.set_fg(FG)
        shown_sy = sy
    end
end

local function render(mode)
    -- mode: "all" | "line" | "cursor"
    local scrolled = scroll_into_view()
    if scrolled or mode == "all" then
        for sy = 1, VIEW do draw_line(sy) end
    else
        if shown_sy and shown_sy >= 1 and shown_sy <= VIEW then
            -- repaint the row that held the cursor block (removes the old block)
            draw_line(shown_sy)
        end
        if mode == "line" then draw_line(cy - top + 1) end
    end
    draw_status()
    draw_cursor(true)
end

local function insert_text(text)
    local line = lines[cy]
    local before, after = line:sub(1, cx - 1), line:sub(cx)
    local parts = {}
    for piece in (text .. "\n"):gmatch("([^\n]*)\n") do parts[#parts + 1] = piece end
    if #parts == 1 then
        lines[cy] = before .. parts[1] .. after
        cx = cx + #parts[1]
    else
        lines[cy] = before .. parts[1]
        for i = 2, #parts - 1 do
            table.insert(lines, cy + i - 1, parts[i])
        end
        table.insert(lines, cy + #parts - 1, parts[#parts] .. after)
        cy = cy + #parts - 1
        cx = #parts[#parts] + 1
    end
    modified = true
    return #parts > 1
end

local function save()
    local ok, err = fs.write_file(path, table.concat(lines, "\n") .. "\n")
    if ok then
        modified = false
        message = "saved"
    else
        message = "save failed: " .. tostring(err)
    end
end

local K = { left = 203, right = 205, up = 200, down = 208, home = 199, end_ = 207,
            pgup = 201, pgdn = 209, delete = 211, back = 14, enter = 28, tab = 15 }

local function run()
    gpu.set_bg(BG)
    gpu.set_fg(FG)
    gpu.fill(1, 1, W, H, " ")
    render("all")

    while true do
        local ev = event.pull(nil, nil, function(e) return e.type == "key_down" or e.type == "clipboard" end)
        local mode = "cursor"
        local typed_quit = false
        message = ""

        if ev.type == "clipboard" then
            if insert_text((tostring(ev.data[3] or ""):gsub("\r", ""):gsub("\t", "    "))) then mode = "all" else mode = "line" end
        else
            local char, code = ev.data[3], ev.data[4]
            if char == 17 then                                  -- Ctrl+Q
                if modified and not quit_armed then
                    message = "unsaved changes - Ctrl+Q again to discard"
                    quit_armed, typed_quit = true, true
                else
                    return
                end
            elseif char == 19 then                              -- Ctrl+S
                save()
            elseif code == K.up then cy = cy - 1
            elseif code == K.down then cy = cy + 1
            elseif code == K.left then
                if cx > 1 then cx = cx - 1 elseif cy > 1 then cy = cy - 1; cx = #lines[cy] + 1 end
            elseif code == K.right then
                if cx <= #lines[cy] then cx = cx + 1 elseif cy < #lines then cy = cy + 1; cx = 1 end
            elseif code == K.home then cx = 1
            elseif code == K.end_ then cx = #lines[cy] + 1
            elseif code == K.pgup then cy = cy - VIEW
            elseif code == K.pgdn then cy = cy + VIEW
            elseif code == K.delete then
                local line = lines[cy]
                if cx <= #line then
                    lines[cy] = line:sub(1, cx - 1) .. line:sub(cx + 1)
                    modified, mode = true, "line"
                elseif cy < #lines then
                    lines[cy] = line .. table.remove(lines, cy + 1)
                    modified, mode = true, "all"
                end
            elseif char == 8 or code == K.back then
                local line = lines[cy]
                if cx > 1 then
                    lines[cy] = line:sub(1, cx - 2) .. line:sub(cx)
                    cx = cx - 1
                    modified, mode = true, "line"
                elseif cy > 1 then
                    local prev = lines[cy - 1]
                    lines[cy - 1] = prev .. line
                    table.remove(lines, cy)
                    cy, cx = cy - 1, #prev + 1
                    modified, mode = true, "all"
                end
            elseif char == 13 or code == K.enter then
                insert_text("\n")
                mode = "all"
            elseif char == 9 or code == K.tab then
                insert_text("    ")
                mode = "line"
            elseif char and char >= 32 and char < 127 then
                insert_text(string.char(char))
                mode = "line"
            end
        end

        if not typed_quit then quit_armed = false end
        clamp()
        render(mode)
    end
end

router.watch_input(proc.pid)
local ok, err = pcall(run)
router.unwatch_input(proc.pid)
if capability.is_valid(gpu) then
    gpu.set_bg(BG)
    gpu.set_fg(FG)
end
term.redraw()
if not ok then
    stderr:write("edit: " .. tostring(err) .. "\n")
    process_manager.exit(1)
end
