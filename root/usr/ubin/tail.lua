-- tail.lua - output the last part of files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- -n +N prints from line N on (-c +N from byte N). -f is not supported.

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("tail", "Print the last 10 lines of each FILE to standard output.")
parser:option("-n --lines", "output the last N lines, or from line N with +N"):argname("[+]N")
parser:option("-c --bytes", "output the last N bytes, or from byte N with +N"):argname("[+]N")
parser:flag("-q --quiet --silent", "never output headers giving file names"):target("quiet")
parser:flag("-v --verbose", "always output headers giving file names")
parser:flag("-f --follow", "output appended data as the file grows (unsupported)")
parser:argument("file", "input file, '-' is standard input"):args("*")

local opts = textio.parse("tail", parser,
    textio.fixnum({ ... }, "nc", { ["--lines"] = true, ["--bytes"] = true }))
if opts.follow then textio.fail("tail", "-f (follow) is not supported") end

-- returns count, fromStart
local function count(text, what)
    local plus = text:match("^%+(%d+)$")
    if plus then return tonumber(plus), true end
    local n = tonumber((text:gsub("^%-", "")))
    if not n or n ~= math.floor(n) or n < 0 then
        textio.fail("tail", "invalid number of " .. what .. ": '" .. text .. "'")
    end
    return n, false
end

local lines, fromStart, bytes, bytesFromStart = 10, false, nil, false
if opts.lines then lines, fromStart = count(opts.lines, "lines") end
if opts.bytes then bytes, bytesFromStart = count(opts.bytes, "bytes") end

local inputs = #opts.file > 0 and opts.file or { "-" }
local header = (#inputs > 1 and not opts.quiet) or opts.verbose
local firstFile = true

return textio.each("tail", inputs, function(name, readLine, file)
    if header then
        io.write(firstFile and "" or "\n", "==> ", name == "-" and "standard input" or name, " <==\n")
    end
    firstFile = false
    if bytes then
        local read = textio.chunks(file)
        if bytesFromStart then
            local skip = math.max(bytes - 1, 0)
            while true do
                local data = read()
                if not data then break end
                local drop = math.min(#data, skip)
                skip = skip - drop
                io.write(data:sub(drop + 1))
            end
        else
            local keep, size = {}, 0
            while true do
                local data = read()
                if not data then break end
                keep[#keep + 1] = data
                size = size + #data
                while #keep > 1 and size - #keep[1] >= bytes do
                    size = size - #table.remove(keep, 1)
                end
            end
            if bytes > 0 then io.write((table.concat(keep):sub(-bytes))) end
        end
    elseif fromStart then
        local n = 0
        while true do
            local line, nl = readLine()
            if not line then break end
            n = n + 1
            if n >= lines then io.write(line, nl and "\n" or "") end
        end
    else
        local ring, head, size = {}, 1, 0
        while lines > 0 do
            local line, nl = readLine()
            if not line then break end
            local entry = { line, nl }
            if size < lines then
                size = size + 1
                ring[(head + size - 2) % lines + 1] = entry
            else
                ring[head] = entry
                head = head % lines + 1
            end
        end
        for i = 0, size - 1 do
            local entry = ring[(head + i - 1) % lines + 1]
            io.write(entry[1], entry[2] and "\n" or "")
        end
    end
end)
