-- head.lua - output the first part of files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- A negative count (-n -N, -c -N) prints all but the last N lines (bytes);
-- "head -5" is the same as "head -n 5".

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("head", "Print the first 10 lines of each FILE to standard output.")
parser:option("-n --lines", "print the first N lines; with -N, all but the last N"):argname("[-]N")
parser:option("-c --bytes", "print the first N bytes; with -N, all but the last N"):argname("[-]N")
parser:flag("-q --quiet --silent", "never print headers giving file names"):target("quiet")
parser:flag("-v --verbose", "always print headers giving file names")
parser:argument("file", "input file, '-' is standard input"):args("*")

local opts = textio.parse("head", parser,
    textio.fixnum({ ... }, "nc", { ["--lines"] = true, ["--bytes"] = true }))

local function number(text, what)
    local n = tonumber(text)
    if not n or n ~= math.floor(n) then
        textio.fail("head", "invalid number of " .. what .. ": '" .. text .. "'")
    end
    return n
end

local lines, bytes = 10, nil
if opts.lines then lines = number(opts.lines, "lines") end
if opts.bytes then bytes = number(opts.bytes, "bytes") end

local inputs = #opts.file > 0 and opts.file or { "-" }
local header = (#inputs > 1 and not opts.quiet) or opts.verbose
local first = true

return textio.each("head", inputs, function(name, readLine, file)
    if header then
        io.write(first and "" or "\n", "==> ", name == "-" and "standard input" or name, " <==\n")
    end
    first = false
    if bytes and bytes < 0 then
        local hold, read = "", textio.chunks(file)
        while true do
            local data = read()
            if not data then break end
            hold = hold .. data
            if #hold > -bytes then
                io.write(hold:sub(1, #hold + bytes))
                hold = hold:sub(#hold + bytes + 1)
            end
        end
    elseif bytes then
        local left, read = bytes, textio.chunks(file)
        while left > 0 do
            local data = read()
            if not data then break end
            io.write(data:sub(1, left))
            left = left - #data
        end
    elseif lines < 0 then
        local queue, first_i = {}, 1
        while true do
            local line, nl = readLine()
            if not line then break end
            queue[#queue + 1] = { line, nl }
            if #queue - first_i + 1 > -lines then
                io.write(queue[first_i][1], queue[first_i][2] and "\n" or "")
                queue[first_i] = nil
                first_i = first_i + 1
            end
        end
    else
        for _ = 1, lines do
            local line, nl = readLine()
            if not line then break end
            io.write(line, nl and "\n" or "")
        end
    end
end)
