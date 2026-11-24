-- wc.lua - print newline, word, character and byte counts
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("wc", "Print newline, word, and byte counts for each FILE.")
parser:flag("-c --bytes", "print the byte counts")
parser:flag("-m --chars", "print the character counts")
parser:flag("-l --lines", "print the newline counts")
parser:flag("-w --words", "print the word counts")
parser:flag("-L --max-line-length", "print the maximum display width"):target("maxlen")
parser:argument("file", "input file, '-' is standard input"):args("*")

local opts = textio.parse("wc", parser, { ... })
local any = opts.lines or opts.words or opts.chars or opts.bytes or opts.maxlen
local show = {
    l = opts.lines or not any,
    w = opts.words or not any,
    m = opts.chars,
    c = opts.bytes or not any,
    L = opts.maxlen,
}

local function count(file)
    local read = textio.chunks(file)
    local n = { l = 0, w = 0, m = 0, c = 0, L = 0 }
    local inWord, col = false, 0
    while true do
        local data = read()
        if not data then break end
        n.c = n.c + #data
        local _, nl = data:gsub("\n", "")
        n.l = n.l + nl
        -- UTF-8 continuation bytes do not start a character
        local _, cont = data:gsub("[\128-\191]", "")
        n.m = n.m + #data - cont
        for i = 1, #data do
            local ch = data:byte(i)
            if ch == 10 then col = 0
            elseif ch == 9 then col = (col // 8 + 1) * 8
            elseif ch < 128 or ch > 191 then col = col + 1 end
            if col > n.L then n.L = col end
            if data:find("^%s", i) then
                inWord = false
            elseif not inWord then
                inWord = true
                n.w = n.w + 1
            end
        end
    end
    return n
end

local function row(n, name)
    local out = {}
    for _, k in ipairs({ "l", "w", "m", "c", "L" }) do
        if show[k] then out[#out + 1] = string.format("%7d", n[k]) end
    end
    if name then out[#out + 1] = name end
    io.write(table.concat(out, " "), "\n")
end

local total = { l = 0, w = 0, m = 0, c = 0, L = 0 }
local inputs = #opts.file > 0 and opts.file or { "-" }
local status = textio.each("wc", inputs, function(name, _, file)
    local n = count(file)
    for k, v in pairs(n) do
        total[k] = (k == "L") and math.max(total[k], v) or total[k] + v
    end
    row(n, (#opts.file > 0) and name or nil)
end)
if #inputs > 1 then row(total, "total") end
return status
