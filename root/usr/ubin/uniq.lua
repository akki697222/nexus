-- uniq.lua - report or omit repeated lines
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("uniq", "Filter adjacent matching lines from INPUT, writing to OUTPUT.")
parser:flag("-c --count", "prefix lines by the number of occurrences")
parser:flag("-d --repeated", "only print duplicate lines, one for each group")
parser:flag("-D", "print all duplicate lines"):target("allrepeated")
parser:flag("-u --unique", "only print unique lines")
parser:flag("-i --ignore-case", "ignore differences in case when comparing")
parser:option("-f --skip-fields", "avoid comparing the first N fields"):argname("N"):convert(tonumber)
parser:option("-s --skip-chars", "avoid comparing the first N characters"):argname("N"):convert(tonumber)
parser:option("-w --check-chars", "compare no more than N characters in lines"):argname("N"):convert(tonumber)
parser:argument("input", "input file, '-' is standard input"):args("?")
parser:argument("output", "output file"):args("?")

local opts = textio.parse("uniq", parser, { ... })

local function key(line)
    local k = line
    for _ = 1, opts.skip_fields or 0 do
        k = k:gsub("^[ \t]*[^ \t]*", "", 1)
    end
    if opts.skip_chars then k = k:sub(opts.skip_chars + 1) end
    if opts.check_chars then k = k:sub(1, opts.check_chars) end
    if opts.ignore_case then k = k:lower() end
    return k
end

local out = { write = function(_, ...) return io.write(...) end, close = function() end }
if opts.output and opts.output ~= "-" then
    local err
    out, err = fs.open(opts.output, "wb")
    if not out then textio.fail("uniq", opts.output .. ": " .. tostring(err)) end
end

local function emit(group)
    local n = #group
    if opts.repeated and n < 2 then return end
    if opts.unique and n > 1 then return end
    if opts.allrepeated then
        if n < 2 then return end
        for _, line in ipairs(group) do out:write(line, "\n") end
        return
    end
    if opts.count then out:write(string.format("%7d ", n)) end
    out:write(group[1], "\n")
end

local status = textio.each("uniq", { opts.input or "-" }, function(_, readLine)
    local group, prevKey
    while true do
        local line = readLine()
        if not line then break end
        local k = key(line)
        if group and k == prevKey then
            group[#group + 1] = line
        else
            if group then emit(group) end
            group, prevKey = { line }, k
        end
    end
    if group then emit(group) end
end)
out:close()
return status
