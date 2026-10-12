-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- lineedit: single-line editor state machine (cursor, history, tab completion).
-- It only manages text; the caller draws it.
--
--   local ed = lineedit.new{ maxlen = 60, history = hist, complete = fn }
--   local r = ed:key(char, code)     -- "enter" | "eof" | "interrupt" | nil
--   ed.buf, ed.pos                   -- text and cursor offset (0..#buf)

local lineedit = {}

-- key codes (OC / LWJGL)
local K = { left = 203, right = 205, up = 200, down = 208, home = 199, end_ = 207,
            delete = 211, back = 14, enter = 28, tab = 15 }

local Editor = {}
Editor.__index = Editor

---@param opts { maxlen: integer?, history: string[]?, history_max: integer?, complete: (fun(prefix: string): string?)? }
function lineedit.new(opts)
    opts = opts or {}
    local ed = setmetatable({
        buf         = "",
        pos         = 0,
        maxlen      = opts.maxlen or 200,
        history     = opts.history or {},
        history_max = opts.history_max or 50,
        complete    = opts.complete,
        saved       = "",
    }, Editor)
    ed.hist_i = #ed.history + 1
    return ed
end

function Editor:insert(text)
    text = tostring(text):gsub("[^\32-\126]", "")
    if text == "" then return end
    text = text:sub(1, self.maxlen - #self.buf)
    self.buf = self.buf:sub(1, self.pos) .. text .. self.buf:sub(self.pos + 1)
    self.pos = self.pos + #text
end

local function remember(self)
    local h = self.history
    if self.buf ~= "" and h[#h] ~= self.buf then
        h[#h + 1] = self.buf
        if #h > self.history_max then table.remove(h, 1) end
    end
end

---Feed one key press. Returns "enter", "eof", "interrupt" or nil.
function Editor:key(char, code)
    if char == 13 or code == K.enter then
        remember(self)
        return "enter"
    elseif char == 3 then
        return "interrupt"
    elseif char == 4 and self.buf == "" then
        return "eof"
    elseif char == 8 or code == K.back then
        if self.pos > 0 then
            self.buf = self.buf:sub(1, self.pos - 1) .. self.buf:sub(self.pos + 1)
            self.pos = self.pos - 1
        end
    elseif code == K.delete then
        self.buf = self.buf:sub(1, self.pos) .. self.buf:sub(self.pos + 2)
    elseif code == K.left then
        if self.pos > 0 then self.pos = self.pos - 1 end
    elseif code == K.right then
        if self.pos < #self.buf then self.pos = self.pos + 1 end
    elseif code == K.home or char == 1 then
        self.pos = 0
    elseif code == K.end_ or char == 5 then
        self.pos = #self.buf
    elseif char == 21 then                              -- Ctrl+U
        self.buf, self.pos = self.buf:sub(self.pos + 1), 0
    elseif code == K.up then
        if self.hist_i > 1 then
            if self.hist_i == #self.history + 1 then self.saved = self.buf end
            self.hist_i = self.hist_i - 1
            self.buf = self.history[self.hist_i]:sub(1, self.maxlen)
            self.pos = #self.buf
        end
    elseif code == K.down then
        if self.hist_i <= #self.history then
            self.hist_i = self.hist_i + 1
            self.buf = self.hist_i == #self.history + 1 and self.saved
                or self.history[self.hist_i]:sub(1, self.maxlen)
            self.pos = #self.buf
        end
    elseif char == 9 or code == K.tab then
        if self.complete then
            local ok, res = pcall(self.complete, self.buf:sub(1, self.pos))
            if ok and res then
                res = res:sub(1, self.maxlen)
                self.buf = res .. self.buf:sub(self.pos + 1)
                self.pos = #res
            end
        end
    elseif char and char >= 32 and char < 127 then
        self:insert(string.char(char))
    end
    return nil
end

return lineedit
