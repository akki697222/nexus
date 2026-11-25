-- cut.lua - remove sections from each line of files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- LIST is N, N-M, N-, -M separated by commas. Characters are bytes (-b and
-- -c behave the same).

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("cut", "Print selected parts of lines from each FILE to standard output.")
parser:option("-b --bytes", "select only these bytes"):argname("LIST")
parser:option("-c --characters", "select only these characters"):argname("LIST")
parser:option("-f --fields", "select only these fields"):argname("LIST")
parser:option("-d --delimiter", "use DELIM instead of TAB for field delimiter"):argname("DELIM")
parser:flag("-n", "(ignored)")
parser:flag("-s --only-delimited", "do not print lines not containing delimiters")
parser:flag("--complement", "complement the set of selected bytes, characters or fields")
parser:option("--output-delimiter", "use STRING as the output delimiter"):argname("STRING")
parser:argument("file", "input file, '-' is standard input"):args("*")

local opts = textio.parse("cut", parser, { ... })

local mode, list = "f", opts.fields
if opts.characters then mode, list = "c", opts.characters
elseif opts.bytes then mode, list = "c", opts.bytes end
local chosen = (opts.fields and 1 or 0) + (opts.characters and 1 or 0) + (opts.bytes and 1 or 0)
if chosen == 0 then
    textio.fail("cut", "you must specify a list of bytes, characters, or fields")
elseif chosen > 1 then
    textio.fail("cut", "only one type of list may be specified")
end
if mode == "c" and (opts.delimiter or opts.only_delimited) then
    textio.fail("cut", "an input delimiter may be specified only when operating on fields")
end

local ranges = {}
for part in list:gmatch("[^,]+") do
    local a, b = part:match("^(%d*)%-(%d*)$")
    if a then
        if a == "" and b == "" then textio.fail("cut", "invalid range with no endpoint: -") end
        ranges[#ranges + 1] = { tonumber(a) or 1, tonumber(b) or math.huge }
    elseif part:match("^%d+$") then
        ranges[#ranges + 1] = { tonumber(part), tonumber(part) }
    else
        textio.fail("cut", "invalid byte, character or field list")
    end
end
for _, r in ipairs(ranges) do
    if r[1] == 0 then textio.fail("cut", "fields and positions are numbered from 1") end
    if r[1] > r[2] then textio.fail("cut", "invalid decreasing range") end
end

local function wanted(i)
    for _, r in ipairs(ranges) do
        if i >= r[1] and i <= r[2] then return not opts.complement end
    end
    return opts.complement ~= nil
end

local delim = opts.delimiter or "\t"
if #delim ~= 1 then textio.fail("cut", "the delimiter must be a single character") end
local outDelim = opts.output_delimiter or delim

return textio.each("cut", opts.file, function(_, readLine)
    while true do
        local line = readLine()
        if not line then break end
        if mode == "c" then
            local out = {}
            for i = 1, #line do
                if wanted(i) then out[#out + 1] = line:sub(i, i) end
            end
            io.write(table.concat(out), "\n")
        elseif not line:find(delim, 1, true) then
            if not opts.only_delimited then io.write(line, "\n") end
        else
            local out, i = {}, 0
            for text in (line .. delim):gmatch("(.-)" .. (delim:gsub("%p", "%%%0"))) do
                i = i + 1
                if wanted(i) then out[#out + 1] = text end
            end
            io.write(table.concat(out, outDelim), "\n")
        end
    end
end)
