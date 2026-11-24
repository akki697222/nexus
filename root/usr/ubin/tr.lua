-- tr.lua - translate or delete characters
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Sets take ranges (a-z), escapes (\n \t \\ \NNN) and classes ([:lower:]
-- [:upper:] [:alpha:] [:digit:] [:alnum:] [:space:] [:punct:] [:xdigit:]
-- [:cntrl:]). Byte based.

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("tr", "Translate, squeeze, and/or delete characters from standard input.")
parser:flag("-c -C --complement", "use the complement of SET1"):target("complement")
parser:flag("-d --delete", "delete characters in SET1, do not translate")
parser:flag("-s --squeeze-repeats", "replace repeated characters listed in the last SET with one"):target("squeeze")
parser:flag("-t --truncate-set1", "first truncate SET1 to length of SET2"):target("truncate")
parser:argument("set1")
parser:argument("set2"):args("?")

local opts = textio.parse("tr", parser, { ... })

local CLASSES = {
    lower = "%l", upper = "%u", alpha = "%a", digit = "%d",
    alnum = "%w", space = "%s", punct = "%p", xdigit = "%x", cntrl = "%c",
}

local function expand(spec)
    local out, i = {}, 1
    local function char()
        local c = spec:sub(i, i)
        if c == "\\" then
            local n = spec:sub(i + 1, i + 1)
            local oct = spec:match("^[0-7][0-7]?[0-7]?", i + 1)
            if oct then
                i = i + 1 + #oct
                return string.char(tonumber(oct, 8) % 256)
            end
            i = i + 2
            return ({ n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v" })[n] or n
        end
        i = i + 1
        return c
    end
    while i <= #spec do
        local class = spec:match("^%[:(%a+):%]", i)
        if class then
            local pat = CLASSES[class]
            if not pat then textio.fail("tr", "invalid character class '" .. class .. "'") end
            for b = 0, 255 do
                if string.char(b):find("^" .. pat .. "$") then out[#out + 1] = string.char(b) end
            end
            i = i + #class + 4
        else
            local c = char()
            if spec:sub(i, i) == "-" and i < #spec then
                i = i + 1
                local e = char()
                if e:byte() < c:byte() then
                    textio.fail("tr", "range-endpoints of '" .. c .. "-" .. e .. "' are in reverse collating sequence order")
                end
                for b = c:byte(), e:byte() do out[#out + 1] = string.char(b) end
            else
                out[#out + 1] = c
            end
        end
    end
    return out
end

local set1 = expand(opts.set1)
if opts.complement then
    local inSet = {}
    for _, c in ipairs(set1) do inSet[c] = true end
    set1 = {}
    for b = 0, 255 do
        local c = string.char(b)
        if not inSet[c] then set1[#set1 + 1] = c end
    end
end
local set2 = opts.set2 and expand(opts.set2) or {}

local translate = not opts.delete and #set2 > 0
if opts.delete and not opts.squeeze and opts.set2 then
    textio.fail("tr", "extra operand '" .. opts.set2 .. "'")
end
if not opts.delete and not opts.squeeze and #set2 == 0 then
    textio.fail("tr", "missing operand after '" .. opts.set1 .. "'")
end
if opts.truncate and translate and #set1 > #set2 then
    for i = #set1, #set2 + 1, -1 do set1[i] = nil end
end

local map, member = {}, {}
for i, c in ipairs(set1) do
    member[c] = true
    if translate and map[c] == nil then map[c] = set2[math.min(i, #set2)] end
end
local squeezeSet = {}
for _, c in ipairs(#set2 > 0 and set2 or set1) do squeezeSet[c] = true end

local last
local read = textio.chunks(io.stdin)
while true do
    local data = read()
    if not data then break end
    local buf = {}
    for i = 1, #data do
        local c = data:sub(i, i)
        if opts.delete and member[c] then
            -- dropped
        else
            if translate and map[c] then c = map[c] end
            if not (opts.squeeze and squeezeSet[c] and last == c) then buf[#buf + 1] = c end
            last = c
        end
    end
    io.write(table.concat(buf))
end
return 0
