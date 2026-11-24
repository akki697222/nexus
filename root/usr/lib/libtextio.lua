-- libtextio.lua - shared helpers for the small text utilities
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   local textio = require("textio")
--   textio.parse(tool, parser, args)  run an argparse parser, exit on error
--   textio.fixnum(args, shorts, longs)  make -NUM / "-n -NUM" survive argparse
--   textio.each(tool, paths, fn) open each input ("-" = stdin) and call fn(name, readLine, file)
--   textio.reader(file)          line reader: returns line, hadNewline (nil at EOF)
--   textio.chunks(file)          chunk reader: returns string (nil at EOF)

local fs = require("filesystem")

local M = {}

local function stdinIsTty()
    return io.isatty and io.isatty(0)
end

function M.open(path)
    if path == "-" then return io.stdin end
    if fs.isDirectory(path) then return nil, "Is a directory" end
    return fs.open(path, "rb")
end

function M.close(file)
    if file ~= io.stdin then file:close() end
end

local function fmtFor(file)
    return (file == io.stdin and stdinIsTty()) and "*L" or 4096
end

function M.chunks(file)
    local fmt = fmtFor(file)
    return function()
        local data, err = file:read(fmt)
        if data == nil and err then error(err, 0) end
        return data
    end
end

function M.reader(file)
    local read = M.chunks(file)
    local buf, eof = "", false
    return function()
        while true do
            local i = buf:find("\n", 1, true)
            if i then
                local line = buf:sub(1, i - 1)
                buf = buf:sub(i + 1)
                return line, true
            end
            if eof then
                if #buf > 0 then
                    local line = buf
                    buf = ""
                    return line, false
                end
                return nil
            end
            local data = read()
            if data == nil then eof = true else buf = buf .. data end
        end
    end
end

-- Run fn over every input. Returns 0, or 1 if any input failed.
function M.each(tool, paths, fn)
    if not paths or #paths == 0 then paths = { "-" } end
    local status = 0
    for _, path in ipairs(paths) do
        local file, err = M.open(path)
        if not file then
            io.stderr:write(tool .. ": " .. path .. ": " .. tostring(err) .. "\n")
            status = 1
        else
            local ok, e = pcall(fn, path, M.reader(file), file)
            M.close(file)
            if not ok then
                io.stderr:write(tool .. ": " .. path .. ": " .. tostring(e) .. "\n")
                status = 1
            end
        end
    end
    return status
end

-- Parse args with an argparse parser. On a usage error print
-- "tool: message" and exit with `code` (default 1; grep and sort use 2).
-- --help is handled by argparse itself.
function M.parse(tool, parser, args, code)
    local ok, res = parser:pparse(args)
    if not ok then
        io.stderr:write(tool .. ": " .. tostring(res) .. "\n")
        io.stderr:write("Try '" .. tool .. " --help' for more information.\n")
        os.exit(code or 1)
    end
    return res
end

-- argparse reads "-5" and "-n -5" as options. For head/tail style tools,
-- rewrite "-NUM" into "-nNUM" and glue a negative value onto the option
-- before it ("-n", "-c", "--lines", "--bytes") so it is read as a value.
function M.fixnum(args, shorts, longs)
    local out, i = {}, 1
    while i <= #args do
        local a = args[i]
        local nxt = args[i + 1]
        if a == "--" then
            for j = i, #args do out[#out + 1] = args[j] end
            break
        elseif a:match("^%-%d+$") then
            out[#out + 1] = "-n" .. a:sub(2)
        elseif nxt and nxt:match("^%-%d+$") and a:match("^%-[%a]*[" .. shorts .. "]$") then
            out[#out + 1] = a .. nxt
            i = i + 1
        elseif nxt and nxt:match("^%-%d+$") and longs[a] then
            out[#out + 1] = a .. "=" .. nxt
            i = i + 1
        else
            out[#out + 1] = a
        end
        i = i + 1
    end
    return out
end

-- Print "tool: msg" and exit (1 unless code is given).
function M.fail(tool, msg, usage, code)
    io.stderr:write(tool .. ": " .. msg .. "\n")
    if usage then io.stderr:write("usage: " .. usage .. "\n") end
    os.exit(code or 1)
end

return M
