-- installer/src/tui.lua - dialogs in the style of debian-installer
--
-- A blue screen with a title line and a help line, and one grey dialog
-- box at a time; the selection is white on red. On a monochrome GPU (tier
-- 1, 50x16) the same layout is drawn in black and white with the
-- selection inverted. Every dialog returns nil for Esc (go back).

tui = {}

local gpu, W, H, mono
local C = {}

local KEY = { enter = 28, esc = 1, up = 200, down = 208, left = 203, right = 205, tab = 15,
    back = 14, del = 211, home = 199, ["end"] = 207, pgup = 201, pgdn = 209, space = 57 }

function tui.init()
    local g, s = component.list("gpu")(), component.list("screen")()
    if not g or not s then return false end
    gpu = component.proxy(g)
    gpu.bind(s)
    local mw, mh = gpu.maxResolution()
    W, H = math.min(mw, 80), math.min(mh, 25)
    gpu.setResolution(W, H)
    mono = gpu.getDepth() < 4
    if mono then
        C = { root = 0x000000, rootFg = 0xFFFFFF, win = 0x000000, winFg = 0xFFFFFF, title = 0xFFFFFF,
            sel = 0xFFFFFF, selFg = 0x000000, entry = 0xFFFFFF, entryFg = 0x000000, shadow = 0x000000,
            bar = 0xFFFFFF, barFg = 0x000000 }
    else
        C = { root = 0x0000AA, rootFg = 0xFFFFFF, win = 0xAAAAAA, winFg = 0x000000, title = 0xAA0000,
            sel = 0xAA0000, selFg = 0xFFFFFF, entry = 0x0000AA, entryFg = 0xFFFFFF, shadow = 0x000000,
            bar = 0xAA0000, barFg = 0xFFFFFF }
    end
    tui.title = "Nexus installer"
    return true
end

local function color(fg, bg)
    gpu.setForeground(fg)
    gpu.setBackground(bg)
end

local function put(x, y, text, fg, bg, width)
    if width then text = (text .. string.rep(" ", width)):sub(1, width) end
    color(fg, bg)
    gpu.set(x, y, text)
end

-- Word-wraps text (paragraphs split on "\n") to width.
function tui.wrap(text, width)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
            while #word > width do
                if line ~= "" then lines[#lines + 1] = line line = "" end
                lines[#lines + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
            if line == "" then
                line = word
            elseif #line + 1 + #word <= width then
                line = line .. " " .. word
            else
                lines[#lines + 1] = line
                line = word
            end
        end
        lines[#lines + 1] = line
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    return lines
end

local function screen(help)
    color(C.rootFg, C.root)
    gpu.fill(1, 1, W, H, " ")
    put(1, 1, " " .. tui.title, C.rootFg, C.root, W)
    if not mono then put(1, 2, string.rep("\u{2500}", W), C.rootFg, C.root) end
    put(1, H, " " .. (help or ""), C.rootFg, C.root, W)
end

-- Draws an empty dialog of inner size w x h; returns its inner top left.
local function box(title, w, h)
    w, h = math.min(w, W - 4), math.min(h, H - 5)
    local x = math.floor((W - w - 2) / 2) + 1
    local y = math.floor((H - h - 2) / 2) + 1
    if y < 3 then y = 3 end
    if not mono then
        color(C.shadow, C.shadow)
        gpu.fill(x + 2, y + h + 2, w + 2, 1, " ")
        gpu.fill(x + w + 2, y + 1, 2, h + 1, " ")
    end
    color(C.winFg, C.win)
    gpu.fill(x, y, w + 2, h + 2, " ")
    gpu.set(x, y, "\u{250C}" .. string.rep("\u{2500}", w) .. "\u{2510}")
    gpu.set(x, y + h + 1, "\u{2514}" .. string.rep("\u{2500}", w) .. "\u{2518}")
    for row = y + 1, y + h do
        gpu.set(x, row, "\u{2502}")
        gpu.set(x + w + 1, row, "\u{2502}")
    end
    if title and title ~= "" then
        local t = "[ " .. title:sub(1, w - 4) .. " ]"
        put(x + math.floor((w + 2 - #t) / 2), y, t, mono and C.winFg or C.title, C.win)
    end
    return x + 1, y + 1, w, h
end

-- Waits for a key; returns code, char (or "paste", text).
local function key()
    while true do
        local sig, _, a, b = computer.pullSignal()
        if sig == "key_down" then return b, a end
        if sig == "clipboard" then return "paste", a end
    end
end

local function buttons(x, y, w, labels, focus)
    local parts = {}
    for i, label in ipairs(labels) do parts[i] = "<" .. label .. ">" end
    local width = #table.concat(parts, "   ")
    local bx = x + math.floor((w - width) / 2)
    for i, part in ipairs(parts) do
        local on = focus == i
        put(bx, y, part, on and C.selFg or C.winFg, on and C.sel or C.win)
        bx = bx + #part + 3
    end
end

-- Text with buttons; returns the index of the pressed button, nil for Esc.
-- Text longer than the screen scrolls with <Up> and <Down>.
local function dialog(title, text, labels, focus, help)
    local inner = math.min(W - 8, 64)
    local lines = tui.wrap(text, inner - 2)
    local rows = math.min(#lines, H - 8)
    local h = rows + 3
    local top = 1
    focus = focus or 1
    while true do
        screen(help or (rows < #lines and "<Up>/<Down> scroll  <Tab> move  <Enter> select"
            or "<Tab> move  <Enter> select  <Esc> back"))
        local x, y, w = box(title, inner, h)
        for i = 0, rows - 1 do
            if lines[top + i] then put(x + 1, y + i, lines[top + i], C.winFg, C.win) end
        end
        if top > 1 then put(x + w - 1, y, "\u{2191}", C.winFg, C.win) end
        if top + rows - 1 < #lines then put(x + w - 1, y + rows - 1, "\u{2193}", C.winFg, C.win) end
        buttons(x, y + h - 1, w, labels, focus)
        local code, ch = key()
        if code == KEY.enter then return focus end
        if code == KEY.esc then return nil end
        if code == KEY.tab or code == KEY.right then focus = focus % #labels + 1 end
        if code == KEY.left then focus = (focus - 2) % #labels + 1 end
        if code == KEY.up then top = math.max(1, top - 1) end
        if code == KEY.down then top = math.max(1, math.min(#lines - rows + 1, top + 1)) end
        if type(ch) == "number" and ch > 0 then
            local c = string.char(ch):lower()
            for i, label in ipairs(labels) do
                if label:sub(1, 1):lower() == c then return i end
            end
        end
    end
end

function tui.message(title, text)
    return dialog(title, text, { "Continue" }, 1, "<Enter> continue") ~= nil
end

-- Returns true, false, or nil for Esc.
function tui.yesno(title, text, default)
    local pressed = dialog(title, text, { "Yes", "No" }, default and 1 or 2)
    if pressed == nil then return nil end
    return pressed == 1
end

-- A list to pick one from. items: { label = "..." }. Returns the index.
function tui.menu(title, text, items, selected)
    local inner = math.min(W - 8, 72)
    local lines = tui.wrap(text, inner - 2)
    local maxRows = H - 8 - #lines
    if maxRows < 3 then
        lines = { table.unpack(lines, 1, math.max(1, H - 11)) }
        maxRows = H - 8 - #lines
    end
    local rows = math.min(#items, maxRows)
    local sel, top = selected or 1, 1
    while true do
        if sel < top then top = sel end
        if sel > top + rows - 1 then top = sel - rows + 1 end
        screen("<Up>/<Down> move  <Enter> select  <Esc> back")
        local x, y, w = box(title, inner, #lines + rows + 1)
        for i, line in ipairs(lines) do put(x + 1, y + i - 1, line, C.winFg, C.win) end
        local ly = y + #lines + 1
        for r = 0, rows - 1 do
            local i = top + r
            local item = items[i]
            if item then
                local on = i == sel
                put(x + 2, ly + r, " " .. item.label, on and C.selFg or C.winFg, on and C.sel or C.win, w - 4)
            end
        end
        if top > 1 then put(x + w - 1, ly, "\u{2191}", C.winFg, C.win) end
        if top + rows - 1 < #items then put(x + w - 1, ly + rows - 1, "\u{2193}", C.winFg, C.win) end
        local code = key()
        if code == KEY.enter then return sel end
        if code == KEY.esc then return nil end
        if code == KEY.up then sel = math.max(1, sel - 1) end
        if code == KEY.down then sel = math.min(#items, sel + 1) end
        if code == KEY.pgup then sel = math.max(1, sel - rows) end
        if code == KEY.pgdn then sel = math.min(#items, sel + rows) end
        if code == KEY.home then sel = 1 end
        if code == KEY["end"] then sel = #items end
    end
end

-- Several to pick. items: { label, checked }. Returns the items (checked
-- updated) or nil.
function tui.checklist(title, text, items)
    local inner = math.min(W - 8, 72)
    local lines = tui.wrap(text, inner - 2)
    local rows = math.max(1, math.min(#items, H - 10 - #lines))
    local sel, top = 1, 1
    local onContinue = false
    while true do
        if sel < top then top = sel end
        if sel > top + rows - 1 then top = sel - rows + 1 end
        screen("<Space> toggle <Tab> move <Enter> ok <Esc> back")
        local x, y, w = box(title, inner, #lines + rows + 3)
        for i, line in ipairs(lines) do put(x + 1, y + i - 1, line, C.winFg, C.win) end
        local ly = y + #lines + 1
        for r = 0, rows - 1 do
            local i = top + r
            local item = items[i]
            if item then
                local on = i == sel and not onContinue
                put(x + 2, ly + r, (item.checked and "[*] " or "[ ] ") .. item.label,
                    on and C.selFg or C.winFg, on and C.sel or C.win, w - 4)
            end
        end
        buttons(x, ly + rows + 1, w, { "Continue" }, onContinue and 1 or 0)
        local code = key()
        if code == KEY.esc then return nil end
        if code == KEY.enter then
            if onContinue or #items == 0 then return items end
            onContinue = true
        elseif code == KEY.tab then
            onContinue = not onContinue
        elseif code == KEY.space and not onContinue and items[sel] then
            items[sel].checked = not items[sel].checked
        elseif code == KEY.up then
            onContinue = false
            sel = math.max(1, sel - 1)
        elseif code == KEY.down then
            if sel == #items then onContinue = true else sel = sel + 1 end
        end
    end
end

-- A line of text. opts: { mask = true, default = "..." }. Returns the text
-- or nil.
function tui.input(title, text, opts)
    opts = opts or {}
    local inner = math.min(W - 8, 64)
    local lines = tui.wrap(text, inner - 2)
    if #lines > H - 10 then lines = { table.unpack(lines, 1, H - 10) } end
    local value = opts.default or ""
    while true do
        screen("<Enter> continue  <Esc> back")
        local x, y, w = box(title, inner, #lines + 4)
        for i, line in ipairs(lines) do put(x + 1, y + i - 1, line, C.winFg, C.win) end
        local fw = w - 2
        local shown = opts.mask and string.rep("*", #value) or value
        if #shown >= fw then shown = shown:sub(#shown - fw + 2) end
        put(x + 1, y + #lines + 1, shown, C.entryFg, C.entry, fw)
        put(x + 1 + #shown, y + #lines + 1, " ", C.entry, C.entryFg)
        buttons(x, y + #lines + 3, w, { "Continue" }, 1)
        local code, ch = key()
        if code == KEY.enter then return value end
        if code == KEY.esc then return nil end
        if code == "paste" then
            value = value .. tostring(ch):gsub("[%c]", "")
        elseif code == KEY.back then
            value = value:sub(1, -2)
        elseif type(ch) == "number" and ch >= 32 and ch < 127 then
            value = value .. string.char(ch)
        end
    end
end

-- A progress gauge; returns set(fraction, text).
function tui.progress(title)
    local inner = math.min(W - 8, 64)
    screen("")
    local x, y, w = box(title, inner, 4)
    local barW = w - 8
    local last = { -1, "" }
    return function(fraction, text)
        fraction = math.max(0, math.min(1, fraction))
        local filled = math.floor(fraction * barW + 0.5)
        if filled == last[1] and text == last[2] then return end
        last[1], last[2] = filled, text
        put(x + 1, y, text or "", C.winFg, C.win, w - 2)
        put(x + 2, y + 2, string.rep(" ", filled), C.barFg, C.bar)
        put(x + 2 + filled, y + 2, string.rep(mono and "\u{2591}" or " ", barW - filled), C.winFg, mono and C.win or C.root)
        put(x + 3 + barW, y + 2, string.format("%3d%%", math.floor(fraction * 100 + 0.5)), C.winFg, C.win)
    end
end
