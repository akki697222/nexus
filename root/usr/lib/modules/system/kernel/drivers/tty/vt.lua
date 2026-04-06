---@type devfs
local devfs = require("devfs")
---@type module
local module = require("module")
---@type vfs
local fs = require("filesystem")
---@type oc_component_lib
local component = require("component")
---@type system
local system = require("system")

---@type vt_driver[]
local vts = {}

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
    early          = true
}
vt_driver.__index = vt_driver

---@class self_lnbuf
---@field text string
---@field fg table<integer, integer>
---@field bg table<integer, integer>

local function hex6(n)
    if not n then return "000000" end
    n = tonumber(n) or 0
    return string.format("%06X", n)
end

local function serialize_line(line)
    local text = line.text or ""
    local text_len = #text

    local runs = {}
    local last_fg, last_bg, run_start, run_len = nil, nil, nil, 0
    for i = 1, text_len do
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
        return { text = text, fg = {}, bg = {} }
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

    return { text = text, fg = fg, bg = bg }
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
    self.buf = { { text = "", fg = {}, bg = {} } }
    self.cx, self.cy = 1, 1

    local gpu = self.gpu
    if not gpu then return end

    gpu.freeAllBuffers()
    self.buf_n = gpu.allocateBuffer()

    self.width, self.height = gpu.maxResolution()

    gpu.setResolution(self.width, self.height)
    gpu.setViewport(self.width, self.height)

    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")
end

function vt_driver:reset()
    local gpu = self.gpu
    if not gpu then return end

    self.line_positions = {}
    self.buf = { { text = "", fg = {}, bg = {} } }
    self.cx, self.cy = 1, 1
    self.scscroll = 0
    self.dirty = true

    gpu.freeAllBuffers()
    self.buf_n = gpu.allocateBuffer()

    self.width, self.height = gpu.maxResolution()

    gpu.setResolution(self.width, self.height)
    gpu.setViewport(self.width, self.height)

    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")
end

function vt_driver:read(n) return "" end

-- ============================================================
-- write (fixed: use table.insert-style sequence, avoid holes)
-- ============================================================

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
                    local seq = text:sub(i + 2, j - 1)
                    if ch == "m" then
                        if seq == "" then
                            self.fg = 0xFFFFFF
                            self.bg = 0x000000
                        else
                            for code in seq:gmatch("%d+") do
                                code = tonumber(code)
                                if code == 0 then
                                    self.fg = 0xFFFFFF
                                    self.bg = 0x000000
                                elseif ansi_colors[tostring(code)] then
                                    self.fg = ansi_colors[tostring(code)]
                                end
                            end
                        end
                    end
                    i = j + 1
                    break
                end
                j = j + 1
            end
        elseif c == "\r" then
            self.cx = 1
            i = i + 1
        elseif c == "\n" then
            self.cx = 1
            table.insert(self.buf, { text = "", fg = {}, bg = {} })
            self.cy = #self.buf
            i = i + 1
        elseif c == "\t" then
            local space = 4 - (self.cx - 1) % 4
            for _ = 1, space do self:write(" ") end
            i = i + 1
        else
            -- ensure current line exists as sequence element
            if not self.buf[self.cy] then
                -- if somehow cy is out of range, append empty lines until it's valid
                while #self.buf < self.cy do
                    table.insert(self.buf, { text = "", fg = {}, bg = {} })
                end
            end

            local line = self.buf[self.cy]
            line.text = (line.text or "") .. c
            line.fg[self.cx] = self.fg
            line.bg[self.cx] = self.bg

            self.cx = self.cx + 1
            if self.cx > self.width then
                self.cx = 1
                table.insert(self.buf, { text = "", fg = {}, bg = {} })
                self.cy = #self.buf
            end
            i = i + 1
        end
    end

    -- keep cy consistent with sequence end if needed
    if self.cy > #self.buf then self.cy = #self.buf end
    self.dirty = true

    if self.early then
        --self:update()
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

local updating = false
function vt_driver:update()
    if not self.dirty or updating then return end
    updating = true

    local gpu = self.gpu
    if not gpu then
        updating = false
        return
    end

    -- Scroll out old lines
    while #self.buf > self.height + 1 do
        local line = self.buf[1]
        if not line then break end

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
    end

    local offset = #self.line_positions
    local current_buf_size = #self.buf
    local total_lines = offset + current_buf_size
    local start_line = math.max(1, total_lines - self.height + 1 - self.scscroll)

    local old_buf_n = nil
    if gpu.getActiveBuffer and gpu.setActiveBuffer then
        old_buf_n = gpu.getActiveBuffer()
        gpu.setActiveBuffer(self.buf_n)
    end

    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, self.width, self.height, " ")

    local current_fg = -1
    local current_bg = -1

    -- Batch open the file for the entire update
    local f = fs.open("/tmp/vtbuf", "r")

    for sy = 1, self.height do
        local logical_line_idx = start_line + sy - 1
        local line = nil

        if logical_line_idx >= 1 and logical_line_idx <= total_lines then
            if logical_line_idx <= offset then
                local entry = self.line_positions[logical_line_idx]
                if entry and f then
                    f:seek("set", entry.pos)
                    local data = f:read(entry.len)
                    if data then line = parse_line_from_data(data) end
                end
            else
                local buf_idx = logical_line_idx - offset
                line = self.buf[buf_idx]
            end
        end

        if line and line.text and #line.text > 0 then
            local text_len = #line.text
            local draw_width = math.min(text_len, self.width)
            for x = 1, draw_width do
                local fg = line.fg and line.fg[x] or 0xFFFFFF
                local bg = line.bg and line.bg[x] or 0x000000
                if current_fg ~= fg then
                    current_fg = fg
                    gpu.setForeground(current_fg)
                end
                if current_bg ~= bg then
                    current_bg = bg
                    gpu.setBackground(current_bg)
                end
                gpu.set(x, sy, line.text:sub(x, x))
            end
        end
    end

    if f then f:close() end

    if system.config and system.config.console_vt_debug then
        local vtbuf_size = 0
        vtbuf_size = (fs.size and fs.size("/tmp/vtbuf")) or 0
        local debug_str = string.format(
            "CX:%d CY:%d W:%d H:%d BUF_N:%d LP:%d SCR:%d DIRTY:%s BUF:%d SIZE:%d",
            self.cx, self.cy, self.width, self.height, (self.buf_n or -1), #self.line_positions,
            self.scscroll, tostring(self.dirty), #self.buf, vtbuf_size
        )

        gpu.setForeground(0xFF0000)
        gpu.setBackground(0x000000)
        gpu.set(1, 1, debug_str)
    end

    gpu.bitblt(0, 1, 1, self.width, self.height + 1, self.buf_n, 1, 1)
    if gpu.setActiveBuffer then
        gpu.setActiveBuffer(old_buf_n)
    end

    self.dirty = false
    updating = false
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
                local pre = string.sub(line.text, 1, self.cx - amount - 1)
                local post = string.sub(line.text, self.cx)
                line.text = pre .. post

                local start_del = self.cx - amount
                for _ = 1, amount do
                    table.remove(line.fg, start_del)
                    table.remove(line.bg, start_del)
                end
            end

            self.cx = self.cx - amount
            n = n - amount
        elseif self.cy > 1 then
            local curr_line = self.buf[self.cy]
            local prev_line = self.buf[self.cy - 1]

            local prev_len = #(prev_line.text or "")
            self.cx = prev_len + 1

            prev_line.text = (prev_line.text or "") .. (curr_line.text or "")

            local curr_len = #(curr_line.text or "")
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
    local dev = setmetatable({}, vt_driver)
    devfs.create("ttyv" .. tostring(id), dev)
    dev:init()
    vts[id] = dev
    return dev
end

function vt.get(id)
    return vts[id]
end

---@type kernel_module
return {
    load = function()
        system.createKernelThread(function()
            while true do
                for _, vt in ipairs(vts) do
                    vt:update()
                    vt.early = false
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
        version   = "0.1.0-dev-OC"
    }
}
