---@type devfs
local devfs = require("devfs")
---@type module
local module = require("module")
---@type vfs
local fs = require("filesystem") --[[@as vfs]]
---@type oc_component_lib
local component = require("component")
---@type system
local system = require("system")
local computer = require("computer")
local event = require("event")
local process = require("process")

local vts = {}
local CURSOR_HALF_PERIOD = 0.5

-- Set by the debug module (development builds): draws over the off-screen
-- buffer after the rows and returns the rows it drew over.
local debugOverlay

-- What the GPU is set to (foreground, background, active buffer), so calls
-- that would not change anything are skipped: every GPU call counts
-- against the machine's per-tick call budget. Only the console modules
-- change GPU state (userland may only query it, see policy.lua), and vts
-- sharing a GPU share its record. OpenComputers keeps the colors per
-- buffer (the screen and each video RAM buffer have their own), so they
-- are recorded per buffer: a color set while drawing off screen says
-- nothing about the screen's, and the other way round.
local gpuStates = setmetatable({}, { __mode = "k" })

local function gpuState(gpu)
    local st = gpuStates[gpu]
    if not st then
        st = { colors = {} }
        gpuStates[gpu] = st
    end
    return st
end

-- the color record of the active buffer (none while that is unknown)
local function bufferColors(st)
    if st.active == nil then return {} end
    local c = st.colors[st.active]
    if not c then
        c = {}
        st.colors[st.active] = c
    end
    return c
end

local function setFg(gpu, color)
    local c = bufferColors(gpuState(gpu))
    if c.fg ~= color then
        gpu.setForeground(color)
        c.fg = color
    end
end

local function setBg(gpu, color)
    local c = bufferColors(gpuState(gpu))
    if c.bg ~= color then
        gpu.setBackground(color)
        c.bg = color
    end
end

local function setActive(gpu, n)
    if not gpu.setActiveBuffer then return end
    local st = gpuState(gpu)
    if st.active ~= n then
        gpu.setActiveBuffer(n)
        st.active = n
    end
end

-- after freeAllBuffers / allocateBuffer the GPU draws on the screen again
local function forgetGpuState(gpu)
    gpuStates[gpu] = { active = 0, colors = {} }
end

local ansi_colors = {
    ["30"] = 0x000000,
    ["31"] = 0xFF0000,
    ["32"] = 0x00FF00,
    ["33"] = 0xFFFF00,
    ["34"] = 0x0000FF,
    ["35"] = 0xFF00FF,
    ["36"] = 0x00FFFF,
    ["37"] = 0xFFFFFF,
    ["90"] = 0x808080,
    ["91"] = 0xFF8080,
    ["92"] = 0x80FF80,
    ["93"] = 0xFFFF80,
    ["94"] = 0x8080FF,
    ["95"] = 0xFF80FF,
    ["96"] = 0x80FFFF,
    ["97"] = 0xE0E0E0,
    ["0"]  = 0xFFFFFF
}

---@class vt_driver : console_device
---@field gpu oc_component_gpu|nil
---@field buf self_lnbuf[]
---@field scscroll integer
---@field line_positions {pos:integer, len:integer}[]
local vt_driver = {
    console        = {
        major = 1,
        minor = 1,
    },
    gpu            = nil,
    width          = 0,
    height         = 0,
    cx             = 1,
    cy             = 1,
    fg             = 0xFFFFFF,
    bg             = 0x000000,
    buf            = {},
    buf_n          = -1,
    scscroll       = 0,
    line_positions = {},
    dirty          = false,
    early          = true,
    updating       = false,
}
vt_driver.__index = vt_driver

-- A line holds one cell per screen column: cells[x] is the character drawn
-- in column x. A double-width character (CJK, full-width forms) fills its
-- column and the next one, whose cell is TAIL. Colors are per column too.
---@class self_lnbuf
---@field cells string[]
---@field fg table<integer, integer>
---@field bg table<integer, integer>

local TAIL = ""
local unicodeLib = type(unicode) == "table" and unicode or nil

local function wide_codepoint(cp)
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E)
        or (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA000 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x20000 and cp <= 0x3FFFD)
end

-- Screen columns one character takes: OpenComputers' own measure when it
-- is there (it decides how gpu.set draws), East Asian wide ranges if not.
local function char_width(ch)
    if #ch <= 1 then return 1 end
    if unicodeLib and unicodeLib.charWidth then
        local ok, w = pcall(unicodeLib.charWidth, ch)
        if ok and type(w) == "number" then return w >= 2 and 2 or 1 end
    end
    local ok, cp = pcall(utf8.codepoint, ch)
    if ok and cp and wide_codepoint(cp) then return 2 end
    return 1
end

-- The UTF-8 character starting at byte i (a stray byte on its own).
local function char_at(s, i)
    return s:match("^[\194-\244][\128-\191]+", i) or s:sub(i, i)
end

-- Cells of a line's text, as written to and read from the scrollback file.
local function cells_of(text)
    local cells, i = {}, 1
    while i <= #text do
        local ch = char_at(text, i)
        cells[#cells + 1] = ch
        if char_width(ch) == 2 then cells[#cells + 1] = TAIL end
        i = i + #ch
    end
    return cells
end

local function hex6(n)
    if not n then return "000000" end
    n = tonumber(n) or 0
    return string.format("%06X", n)
end

local function serialize_line(line)
    local cells = line.cells or {}
    local text = table.concat(cells)
    local text_len = #text

    local runs = {}
    local last_fg, last_bg, run_start, run_len = nil, nil, nil, 0
    for i = 1, #cells do
        local fg = line.fg and line.fg[i] or nil
        local bg = line.bg and line.bg[i] or nil
        fg = fg or 0xFFFFFF
        bg = bg or 0x000000
        if last_fg == nil then
            last_fg, last_bg = fg, bg
            run_start = i
            run_len = 1
        else
            if last_fg == fg and last_bg == bg then
                run_len = run_len + 1
            else
                table.insert(runs, string.format("%d,%d,%s,%s;", run_start, run_len, hex6(last_fg), hex6(last_bg)))
                last_fg, last_bg = fg, bg
                run_start = i
                run_len = 1
            end
        end
    end
    if last_fg ~= nil then
        table.insert(runs, string.format("%d,%d,%s,%s;", run_start, run_len, hex6(last_fg), hex6(last_bg)))
    end

    local runs_str = table.concat(runs)
    return tostring(text_len) .. "|" .. text .. "|" .. runs_str .. "\n"
end

local function parse_line_from_data(data)
    if not data or #data == 0 then return nil end
    local p1 = data:find("|", 1, true)
    if not p1 then return nil end
    local len_str = data:sub(1, p1 - 1)
    local text_len = tonumber(len_str)
    if not text_len then return nil end

    local text_start = p1 + 1
    local text_end = text_start + text_len - 1
    if text_end > #data then return nil end
    local text = data:sub(text_start, text_end)

    local sep_pos = text_end + 1
    if data:sub(sep_pos, sep_pos) ~= "|" then
        return { cells = cells_of(text), fg = {}, bg = {} }
    end
    local runs_str = data:sub(sep_pos + 1)
    if runs_str:sub(-1) == "\n" then runs_str = runs_str:sub(1, -2) end

    local fg = {}
    local bg = {}
    for start_s, len_s, fghex, bghex in runs_str:gmatch("(%d+),(%d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+);") do
        local s = tonumber(start_s)
        local l = tonumber(len_s)
        local fgn = tonumber(fghex, 16) or 0xFFFFFF
        local bgn = tonumber(bghex, 16) or 0x000000
        for i = s, s + l - 1 do
            fg[i] = fgn
            bg[i] = bgn
        end
    end

    return { cells = cells_of(text), fg = fg, bg = bg }
end

local function append_line_to_file(self, str)
    local fa = fs.open("/tmp/vtbuf", "a")
    if fa then
        local pos = 0
        if fa.seek then
            pos = fa:seek("end", 0) or 0
        else
            pos = (fs.size and fs.size("/tmp/vtbuf")) or 0
        end
        fa:write(str)
        fa:close()
        return pos, #str
    end

    local fw = fs.open("/tmp/vtbuf", "w")
    if fw then
        local pos = 0
        if fw.seek then
            pos = fw:seek("end", 0) or 0
        else
            pos = (fs.size and fs.size("/tmp/vtbuf")) or 0
        end
        fw:write(str)
        fw:close()
        return pos, #str
    end

    return nil, nil
end

function vt_driver:init()
    self.gpu = component.proxy(component.list("gpu")())

    self.scscroll = 0
    self.line_positions = {}
    self.buf = { { cells = {}, fg = {}, bg = {} } }
    self.cx, self.cy = 1, 1

    local gpu = self.gpu
    if not gpu then return end

    gpu.freeAllBuffers()
    self.buf_n = gpu.allocateBuffer()
    forgetGpuState(gpu)

    self.width, self.height = gpu.maxResolution()

    gpu.setResolution(self.width, self.height)
    gpu.setViewport(self.width, self.height)

    setActive(gpu, 0)
    setFg(gpu, 0xFFFFFF)
    setBg(gpu, 0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")
    self:invalidate()
end

function vt_driver:reset()
    local gpu = self.gpu
    if not gpu then return end

    self.line_positions = {}
    self.buf = { { cells = {}, fg = {}, bg = {} } }
    self.cx, self.cy = 1, 1
    self.scscroll = 0
    self:invalidate()
    self.cursorOverlay = nil

    gpu.freeAllBuffers()
    self.buf_n = gpu.allocateBuffer()
    forgetGpuState(gpu)

    self.width, self.height = gpu.maxResolution()

    gpu.setResolution(self.width, self.height)
    gpu.setViewport(self.width, self.height)

    setActive(gpu, 0)
    setFg(gpu, 0xFFFFFF)
    setBg(gpu, 0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")
end

-- Forgets the scrollback (the lines already written to /tmp/vtbuf stay in
-- the file, which other vts share).
function vt_driver:dropScrollback()
    self.line_positions = {}
    self.scscroll = 0
    self.scrollCache, self.scrollCacheSize = nil, 0
end

-- clear(1): an empty screen with the cursor at the top, and no scrollback
-- above it (as `clear` does with ESC[3J), so nothing old comes back into
-- view.
function vt_driver:clear()
    local gpu = self.gpu
    if not gpu then return end

    self.buf = { { cells = {}, fg = {}, bg = {} } }
    if not self.alt then self:dropScrollback() end
    self.cx, self.cy = 1, 1
    self.scscroll = 0
    self:invalidate()
    self.cursorOverlay = nil

    setActive(gpu, 0)
    setFg(gpu, 0xFFFFFF)
    setBg(gpu, 0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")
end

function vt_driver:read(n) return "" end

-- ============================================================
-- write (fixed: use table.insert-style sequence, avoid holes)
-- ============================================================

local function new_line() return { cells = {}, fg = {}, bg = {} } end

function vt_driver:charWidth(ch) return char_width(ch) end

-- Screen row (1-based) of the current view -> index into self.buf, growing
-- the buffer when the row is below its last line.
function vt_driver:rowToLine(row)
    local offset = #self.line_positions
    local total = offset + #self.buf
    local start_line = math.max(1, total - self.height + 1)
    local idx = start_line + row - 1 - offset
    if idx < 1 then idx = 1 end
    while #self.buf < idx do table.insert(self.buf, new_line()) end
    return idx
end

-- Writes one character at the cursor, overwriting what is there (padding
-- with blanks past the end of the line), then advances the cursor. A
-- double-width character that does not fit in the row moves to the next.
function vt_driver:putChar(c)
    if not self.buf[self.cy] then
        while #self.buf < self.cy do table.insert(self.buf, new_line()) end
    end
    local line = self.buf[self.cy]
    local w = char_width(c)
    local cx = self.cx
    if cx + w - 1 > self.width then
        if self.alt then return end -- no autowrap on the alternate screen
        self.cx, cx = 1, 1
        table.insert(self.buf, self.cy + 1, new_line())
        self.cy = self.cy + 1
        line = self.buf[self.cy]
    end
    local cells = line.cells
    for i = #cells + 1, cx - 1 do
        cells[i] = " "
        line.fg[i], line.bg[i] = 0xFFFFFF, 0x000000
    end
    -- a double-width character partly overwritten loses its other half
    if cells[cx] == TAIL and cx > 1 then cells[cx - 1] = " " end
    if cells[cx + w] == TAIL then cells[cx + w] = " " end
    cells[cx] = c
    line.fg[cx], line.bg[cx] = self.fg, self.bg
    if w == 2 then
        cells[cx + 1] = TAIL
        line.fg[cx + 1], line.bg[cx + 1] = self.fg, self.bg
    end
    self.cx = cx + w
    if self.cx > self.width and not self.alt then
        self.cx = 1
        table.insert(self.buf, self.cy + 1, new_line())
        self.cy = self.cy + 1
    end
end

local function sgr(self, seq)
    if seq == "" then seq = "0" end
    for code in seq:gmatch("%d+") do
        local n = tonumber(code)
        if n == 0 then
            self.fg, self.bg, self.inverse = 0xFFFFFF, 0x000000, false
        elseif n == 7 then
            if not self.inverse then self.fg, self.bg, self.inverse = self.bg, self.fg, true end
        elseif n == 27 then
            if self.inverse then self.fg, self.bg, self.inverse = self.bg, self.fg, false end
        elseif n == 39 then
            self.fg = 0xFFFFFF
        elseif n == 49 then
            self.bg = 0x000000
        elseif (n >= 40 and n <= 47) or (n >= 100 and n <= 107) then
            self.bg = ansi_colors[tostring(n - 10)] or self.bg
        elseif ansi_colors[code] then
            self.fg = ansi_colors[code]
        end
    end
end

-- CSI sequences: SGR colors (m), cursor position (H/f), erase display (J),
-- erase line (K), alternate screen (?1049h/l) and cursor visibility (?25h/l).
function vt_driver:csi(seq, final)
    if final == "m" then
        sgr(self, seq)
    elseif final == "H" or final == "f" then
        local row, col = seq:match("^(%d*);?(%d*)$")
        row = math.max(1, math.min(tonumber(row) or 1, self.height))
        col = math.max(1, math.min(tonumber(col) or 1, self.width))
        self.cy = self:rowToLine(row)
        self.cx = col
    elseif final == "K" then
        local line = self.buf[self.cy]
        if line and (seq == "" or seq == "0") then
            local cells = line.cells
            if cells[self.cx] == TAIL and self.cx > 1 then cells[self.cx - 1] = " " end
            for i = #cells, self.cx, -1 do cells[i] = nil end
            for i = self.cx, #line.fg do line.fg[i], line.bg[i] = nil, nil end
        elseif line and seq == "2" then
            self.buf[self.cy] = new_line()
        end
    elseif final == "J" and seq == "3" then
        -- erase the saved lines; the screen stays as it is
        if not self.alt then
            self:dropScrollback()
            self:invalidate()
        end
    elseif final == "J" and seq == "2" then
        -- erase the screen: a screenful of blank lines, so the view shows
        -- them and not the scrollback above (which is kept)
        self.buf = {}
        for _ = 1, self.height do table.insert(self.buf, new_line()) end
        self.cx, self.cy = 1, 1
        self:invalidate()
    elseif final == "h" and seq == "?1049" and not self.alt then
        self.saved = { buf = self.buf, line_positions = self.line_positions, cx = self.cx, cy = self.cy,
            scscroll = self.scscroll, fg = self.fg, bg = self.bg }
        self.alt = true
        self.buf = {}
        for _ = 1, self.height do table.insert(self.buf, new_line()) end
        self.line_positions = {}
        self.cx, self.cy, self.scscroll = 1, 1, 0
        self:invalidate()
    elseif final == "l" and seq == "?1049" and self.alt then
        local saved = self.saved
        self.alt, self.saved = false, nil
        self.buf, self.line_positions = saved.buf, saved.line_positions
        self.cx, self.cy, self.scscroll = saved.cx, saved.cy, saved.scscroll
        self.fg, self.bg = saved.fg, saved.bg
        self:invalidate()
    elseif seq == "?25" and (final == "h" or final == "l") then
        self.cursorHidden = final == "l"
    end
end

function vt_driver:write(...)
    local text = tostring(table.concat({...}) or "")
    if text == "" then return end
    local i = 1
    local len = #text

    while i <= len do
        local c = text:sub(i, i)

        if c == "\27" and text:sub(i + 1, i + 1) == "[" then
            local j = i + 2
            while j <= len do
                local ch = text:sub(j, j)
                if ch:match("[%@A-Za-z]") then
                    self:csi(text:sub(i + 2, j - 1), ch)
                    break
                end
                j = j + 1
            end
            i = j + 1
        elseif c == "\r" then
            self.cx = 1
            i = i + 1
        elseif c == "\n" then
            self.cx = 1
            if self.cy < #self.buf then
                self.cy = self.cy + 1
            else
                table.insert(self.buf, new_line())
                self.cy = #self.buf
            end
            i = i + 1
        elseif c == "\t" then
            local space = 4 - (self.cx - 1) % 4
            for _ = 1, space do self:putChar(" ") end
            i = i + 1
        else
            local ch = char_at(text, i)
            self:putChar(ch)
            i = i + #ch
        end
    end

    -- keep cy consistent with sequence end if needed
    if self.cy > #self.buf then self.cy = #self.buf end
    self.dirty = true

    if self.early then
        self:update()
    end
end

-- ============================================================
-- scroll / overflow handling
-- ============================================================

function vt_driver:scroll(n)
    if n == 0 then return end
    local offset = #self.line_positions
    local current_buf_size = #self.buf
    local total_lines = offset + current_buf_size
    if total_lines <= self.height then
        self.scscroll = 0
        return
    end
    local max_scroll = total_lines - self.height
    self.scscroll = math.max(0, math.min(self.scscroll + n, max_scroll))
    self.dirty = true
end

function vt_driver:setInputCursor(pid)
    local owner = pid and process.get(pid)
    self.cursorPid = owner and pid or nil
    self.cursorInstance = owner and owner.instance or nil
    if owner then self.cursorSince = computer.uptime() end
end

function vt_driver:updateCursor()
    local gpu = self.gpu
    local previous = self.cursorOverlay
    if not gpu or (not self.cursorPid and not previous) then return end

    local x, y
    if self.cursorPid then
        local owner = process.get(self.cursorPid)
        if not owner or owner.instance ~= self.cursorInstance then
            self.cursorPid = nil
        elseif self.scscroll == 0 and not self.cursorHidden and event.getForeground() == self.cursorPid
            and math.floor((computer.uptime() - self.cursorSince) / CURSOR_HALF_PERIOD) % 2 == 0 then
            x = self.cx
            y = #self.line_positions + self.cy - (self.screenStart or 1) + 1
            if x < 1 or x > self.width or y < 1 or y > self.height then x, y = nil, nil end
        end
    end

    if previous and previous.x == x and previous.y == y then return end
    if previous then
        -- The off-screen frame still has the original text and colors.
        gpu.bitblt(0, previous.x, previous.y, previous.w or 1, 1, self.buf_n, previous.x, previous.y)
        self.cursorOverlay = nil
    end
    if not x then return end

    setActive(gpu, 0)
    -- block cursor: the character under it in inverted colors
    local line = self.buf[self.cy]
    local ch = line and line.cells[self.cx] or ""
    if ch == "" then ch = " " end
    local cw = math.min(char_width(ch), self.width - x + 1)
    local cellFg = line and line.fg[self.cx] or self.fg
    local cellBg = line and line.bg[self.cx] or 0x000000
    if ch == " " then cellFg = self.fg end
    setFg(gpu, cellBg)
    setBg(gpu, cellFg)
    gpu.set(x, y, ch)
    self.cursorOverlay = { x = x, y = y, w = cw }
end

-- Color runs of a line: { x, text, fg, bg, columns } per stretch of equal
-- colors, plus a signature that identifies what the row looks like once
-- drawn. A double-width character is never split between runs.
local function line_runs(line, width)
    local runs, sig = {}, {}
    local cells = line and line.cells or {}
    local n = math.min(#cells, width)
    local fgs, bgs = line and line.fg, line and line.bg
    local x = 1
    while x <= n do
        local fg = fgs and fgs[x] or 0xFFFFFF
        local bg = bgs and bgs[x] or 0x000000
        local e = x
        while e < n do
            local nfg = fgs and fgs[e + 1] or 0xFFFFFF
            local nbg = bgs and bgs[e + 1] or 0x000000
            if (nfg ~= fg or nbg ~= bg) and cells[e + 1] ~= TAIL then break end
            e = e + 1
        end
        local piece = table.concat(cells, "", x, e)
        runs[#runs + 1] = { x, piece, fg, bg, e - x + 1 }
        sig[#sig + 1] = x .. ":" .. fg .. ":" .. bg .. ":" .. piece
        x = e + 1
    end
    return runs, table.concat(sig, "\0")
end

-- Forget what the off-screen buffer holds; the next update redraws all rows.
function vt_driver:invalidate()
    self.drawn = nil
    self.drawnStart = nil
    self.dirty = true
end

-- Redraws only the rows whose content changed since the last update, one
-- gpu.set per color run, shifts the off-screen buffer with gpu.copy when
-- the view scrolled, and blits only the changed rows to the screen.
function vt_driver:update()
    if self.updating then return end
    if not self.dirty then
        self:updateCursor()
        return
    end
    self.updating = true

    local gpu = self.gpu
    if not gpu then
        self.updating = false
        return
    end

    -- Scroll out old lines (the alternate screen keeps no scrollback)
    while #self.buf > self.height + 1 do
        local line = self.buf[1]
        if not line then break end
        if self.alt then
            table.remove(self.buf, 1)
            self.cy = math.max(1, self.cy - 1)
            goto continue
        end

        local str = serialize_line(line)
        local pos, len = append_line_to_file(self, str)
        if pos and len then
            table.insert(self.line_positions, { pos = pos, len = len })
            -- Limit line_positions to prevent another leak (e.g., last 1000 lines)
            if #self.line_positions > 1000 then
                table.remove(self.line_positions, 1)
            end
        end

        table.remove(self.buf, 1)
        self.cy = math.max(1, math.min(self.cy - 1, #self.buf + 1))
        ::continue::
    end

    local width, height = self.width, self.height
    local offset = #self.line_positions
    local current_buf_size = #self.buf
    local total_lines = offset + current_buf_size
    local start_line = math.max(1, total_lines - height + 1 - self.scscroll)
    self.screenStart = start_line

    setActive(gpu, self.buf_n)

    -- Scrolled by a few rows: move what is already drawn instead of
    -- redrawing it. Logical line L sits on row L - start_line + 1.
    local drawn = self.drawn
    if drawn and self.drawnStart and self.drawnStart ~= start_line then
        local shift = start_line - self.drawnStart
        if math.abs(shift) < height then
            if shift > 0 then
                gpu.copy(1, shift + 1, width, height - shift, 0, -shift)
            else
                gpu.copy(1, 1, width, height + shift, 0, -shift)
            end
            local moved = {}
            for sy = 1, height do
                local from = sy + shift
                if from >= 1 and from <= height then moved[sy] = drawn[from] end
            end
            drawn = moved
            self.minDirtyRow, self.maxDirtyRow = 1, height
        else
            drawn = nil
        end
    end
    local fullClear = false
    if not drawn then
        -- Nothing reusable: clear once instead of row by row.
        drawn = {}
        self.minDirtyRow, self.maxDirtyRow = 1, height
        setFg(gpu, 0xFFFFFF)
        setBg(gpu, 0x000000)
        gpu.fill(1, 1, width, height, " ")
        fullClear = true
    end

    local f
    local minRow, maxRow = self.minDirtyRow, self.maxDirtyRow
    self.minDirtyRow, self.maxDirtyRow = nil, nil

    for sy = 1, height do
        local logical_line_idx = start_line + sy - 1
        local line = nil

        if logical_line_idx >= 1 and logical_line_idx <= total_lines then
            if logical_line_idx <= offset then
                local entry = self.line_positions[logical_line_idx]
                if entry then
                    -- scrollback rows come from the file once, then from
                    -- the cache: repaints happen on every keystroke
                    local cache = self.scrollCache
                    if not cache or (self.scrollCacheSize or 0) > 4 * height then
                        cache = {}
                        self.scrollCache, self.scrollCacheSize = cache, 0
                    end
                    line = cache[entry.pos]
                    if not line then
                        f = f or fs.open("/tmp/vtbuf", "r") or false
                        if f then
                            f:seek("set", entry.pos)
                            local data = f:read(entry.len)
                            if data then line = parse_line_from_data(data) end
                        end
                        if line then
                            cache[entry.pos] = line
                            self.scrollCacheSize = self.scrollCacheSize + 1
                        end
                    end
                end
            else
                line = self.buf[logical_line_idx - offset]
            end
        end

        local runs, sig = line_runs(line, width)
        if fullClear and sig == "" then
            drawn[sy] = sig -- already blank
        elseif drawn[sy] ~= sig then
            if not fullClear then
                -- only the part the runs leave uncovered needs clearing
                local last = runs[#runs]
                local covered = last and (last[1] + last[5] - 1) or 0
                if covered < width then
                    setBg(gpu, 0x000000)
                    gpu.fill(covered + 1, sy, width - covered, 1, " ")
                end
            end
            for _, run in ipairs(runs) do
                setFg(gpu, run[3])
                setBg(gpu, run[4])
                gpu.set(run[1], sy, run[2])
            end
            drawn[sy] = sig
            if not minRow or sy < minRow then minRow = sy end
            if not maxRow or sy > maxRow then maxRow = sy end
        end
    end

    if f then f:close() end

    if debugOverlay then
        -- rows drawn over are redrawn from the buffer on the next pass
        local rows = debugOverlay(self, gpu, setFg, setBg)
        if rows then
            for _, sy in ipairs(rows) do
                drawn[sy] = nil
                if not minRow or sy < minRow then minRow = sy end
                if not maxRow or sy > maxRow then maxRow = sy end
            end
        end
    end

    self.drawn = drawn
    self.drawnStart = start_line

    if minRow then
        gpu.bitblt(0, 1, minRow, width, maxRow - minRow + 1, self.buf_n, 1, minRow)
        -- A blinking cursor cell inside the blitted rows was overwritten.
        local overlay = self.cursorOverlay
        if overlay and overlay.y >= minRow and overlay.y <= maxRow then
            self.cursorOverlay = nil
        end
    end
    setActive(gpu, 0)

    self.dirty = false
    self.updating = false
    self:updateCursor()
end

function vt_driver:backspace(n)
    n = n or 1
    if n <= 0 then return end

    self.dirty = true

    while n > 0 do
        if self.cx == 1 and self.cy == 1 then
            break
        end

        if self.cx > 1 then
            local amount = math.min(n, self.cx - 1)
            local line = self.buf[self.cy]

            if line then
                local cells = line.cells
                local start_del = self.cx - amount
                for _ = 1, amount do
                    if start_del <= #cells then table.remove(cells, start_del) end
                    table.remove(line.fg, start_del)
                    table.remove(line.bg, start_del)
                end
                -- no half of a double-width character survives on its own
                if cells[start_del] == TAIL then cells[start_del] = " " end
                local before = cells[start_del - 1]
                if before and char_width(before) == 2 and cells[start_del] ~= TAIL then
                    cells[start_del - 1] = " "
                end
            end

            self.cx = self.cx - amount
            n = n - amount
        elseif self.cy > 1 then
            local curr_line = self.buf[self.cy]
            local prev_line = self.buf[self.cy - 1]

            local prev_len = #prev_line.cells
            self.cx = prev_len + 1

            local curr_len = #curr_line.cells
            for i = 1, curr_len do
                prev_line.cells[prev_len + i] = curr_line.cells[i]
            end
            for i = 1, curr_len do
                local dest_idx = prev_len + i
                prev_line.fg[dest_idx] = curr_line.fg[i]
                prev_line.bg[dest_idx] = curr_line.bg[i]
            end

            table.remove(self.buf, self.cy)
            self.cy = self.cy - 1

            n = n - 1
        else
            break
        end
    end
end

function vt_driver:getCursor()
    return self.cx, self.cy
end

function vt_driver:setCursor(cx, cy)
    self.cx, self.cy = cx, cy
end

function vt_driver:getViewport()
    return self.width, self.height, self.cx, self.cy, 1, 1
end

function vt_driver:setViewport(w, h, cx, cy)
    self.width, self.height, self.cx, self.cy = w, h, cx, cy
end

---@class module_vt
local vt = {}

---@param id integer
function vt.new(id)
    local dev = setmetatable({}, {__index = vt_driver})
    dev:init()
    local callbacks = {
        read = function(_handle, ...)
            return dev:read(...)
        end,
        write = function(_handle, value)
            dev:write(value)
            return true
        end,
    }
    devfs.create("ttyv" .. tostring(id), callbacks, false, 620)
    table.insert(vts, {dev = dev, id = id})
    return dev
end

-- The overlay runs in the kernel's repaint thread, so only the kernel
-- itself (module loading) and root may set it.
function vt.setDebugOverlay(fn)
    local cur = process.getCurrent()
    if cur and cur.euid ~= 0 then return nil, "Permission denied" end
    debugOverlay = fn
    for _, drv in ipairs(vts) do drv.dev:invalidate() end
    return true
end

function vt.get(id)
    for _, drv in ipairs(vts) do
        if drv.id == id then
            return drv.dev
        end
    end
    return nil
end

---@type kernel_module
return {
    load = function()
        system.createKernelThread(function()
            while true do
                for _, drv in ipairs(vts) do
                    drv.dev:update()
                    drv.dev.early = false
                end
                coroutine.yield()
            end
        end, "gpu", {})
    end,
    unload = function() end,
    module = vt,
    manifest = {
        name      = "vt",
        desc      = "virtual terminal driver",
        version_n = 1,
        abi = 1,
        version   = "0.1.0-OC"
    }
}
