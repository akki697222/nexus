-- lua.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local function optrequire(...)
    local ok, mod = pcall(require, ...)
    if ok then return mod end
end

local env -- forward declare for binding in metamethod
env = setmetatable({}, {
    __index = function(_, k)
        _ENV[k] = _ENV[k] or optrequire(k)
        return _ENV[k]
    end,
    __pairs = function(t)
        return function(_, key)
            local k, v = next(t, key)
            if not k and t == env then
                t = _ENV
                k, v = next(t)
            end
            if not k and t == _ENV then
                t = package.loaded
                k, v = next(t)
            end
            return k, v
        end
    end,
})
env._PROMPT = tostring(env._PROMPT or "\27[32mlua> \27[37m")

local function findTable(t, path)
    if type(t) ~= "table" then return nil end
    if not path or #path == 0 then return t end
    local name = string.match(path, "[^.]+")
    for k, v in pairs(t) do
        if k == name then
            return findTable(v, string.sub(path, #name + 2))
        end
    end
    local mt = getmetatable(t)
    if t == env then mt = { __index = _ENV } end
    if mt then
        return findTable(mt.__index, path)
    end
    return nil
end

local function findKeys(t, r, prefix, name)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(k) == "string" and string.match(k, "^" .. name) then
            local postfix = ""
            if type(v) == "function" then
                postfix = "()"
            elseif type(v) == "table" and getmetatable(v) and getmetatable(v).__call then
                postfix = "()"
            elseif type(v) == "table" then
                postfix = "."
            end
            r[prefix .. k .. postfix] = true
        end
    end
    local mt = getmetatable(t)
    if t == env then mt = { __index = _ENV } end
    if mt then
        return findKeys(mt.__index, r, prefix, name)
    end
end

local function completionHints(line, index)
    line = line or ""
    local tail = line:sub(index)
    local head = line:sub(1, index - 1)
    local path = string.match(head, "[a-zA-Z_][a-zA-Z0-9_.]*$")
    if not path then return nil end
    local suffix = string.match(path, "[^.]+$") or ""
    local prefix = string.sub(path, 1, #path - #suffix)
    local tbl = findTable(env, prefix)
    if not tbl then return nil end
    local keys, hints = {}, {}
    findKeys(tbl, keys, string.sub(head, 1, #head - #suffix), suffix)
    for key in pairs(keys) do
        table.insert(hints, key .. tail)
    end
    return hints
end

-- Nexus has no serialization module exposed to userland; keep it minimal.
local function serialize(v, seen)
    seen = seen or {}
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "table" then
        if seen[v] then return "<circular>" end
        seen[v] = true
        local parts = {}
        for k, val in pairs(v) do
            local key = (type(k) == "string" and string.match(k, "^[%a_][%w_]*$"))
                and k or ("[" .. serialize(k, seen) .. "]")
            table.insert(parts, key .. "=" .. serialize(val, seen))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return "<" .. t .. ">"
    end
end

-- debug may not exist on the user tier; degrade to a plain message.
local function traceback(msg)
    if debug and debug.traceback then
        return debug.traceback(msg)
    end
    return tostring(msg)
end

-- Runs a loaded chunk, printing results/errors the same way for -e, a
-- script file, and the REPL. Returns the chunk's exit-relevant status.
local function runChunk(code, ...)
    local result = table.pack(xpcall(code, traceback, ...))
    if not result[1] then
        if type(result[2]) == "table" and result[2].reason == "terminated" then
            -- NOTE: unverified whether Nexus's kill(2) delivers termination this
            -- way; adjust if the kernel's signal convention differs.
            os.exit(result[2].code)
        end
        io.stderr:write(tostring(result[2]) .. "\n")
        return false
    end
    return true, result
end

local function repl()
    io.write("\27[37m" .. _VERSION .. " on Nexus " .. tostring(_OSVERSION) .. "\n")
    io.write("\27[33mEnter a statement and hit enter to evaluate it.\n")
    io.write("Prefix an expression with '=' to show its value.\n")
    io.write("Press Ctrl+D to exit the interpreter.\n\27[37m")

    while io.isatty(0) do
        io.write(env._PROMPT)

        -- tty_driver:read() takes the completion callback as a trailing function
        -- argument (not a {hint=...} table), and io.stdin:read() (unlike the
        -- plain io.read()) preserves nil on real EOF instead of coercing to "".
        local command = io.stdin:read(completionHints)
        if not command then return end -- eof

        local code, reason
        if string.sub(command, 1, 1) == "=" then
            code, reason = load("return " .. string.sub(command, 2), "=stdin", "t", env)
        else
            code, reason = load("return " .. command, "=stdin", "t", env)
            if not code then
                code, reason = load(command, "=stdin", "t", env)
            end
        end

        if not code then
            io.stderr:write(tostring(reason) .. "\n")
        else
            local ok, result = runChunk(code)
            if ok then
                local sok, swhy = pcall(function()
                    for i = 2, result.n do
                        io.write(serialize(result[i]), i < result.n and "\t" or "\n")
                    end
                end)
                if not sok then
                    io.stderr:write("crashed serializing result: " .. tostring(swhy) .. "\n")
                end
            end
        end
    end
end

-- CLI entry point --------------------------------------------------------

local argparse = require("argparse")
local parser = argparse("lua", "Nexus Lua interpreter")
parser:option("-e --execute", "Execute string 'stat'.")
parser:flag("-i --interactive", "Enter interactive mode after running 'script'.")
parser:argument("script", "Lua script to run."):args("?")
parser:argument("args", "Arguments passed to 'script'."):args("*")

-- process.exec() delivers argv as this chunk's own top-level `...`, not a
-- global `arg` table, so hand that straight to argparse.
local ok, args = parser:pparse({ ... })
if not ok then
    io.stderr:write(tostring(args) .. "\n")
    os.exit(1)
end

local ran_something = false

if args.execute then
    local code, err = load(args.execute, "=(command line)", "t", env)
    if not code then
        io.stderr:write(tostring(err) .. "\n")
        os.exit(1)
    end
    local ok2 = runChunk(code, table.unpack(args.args or {}))
    ran_something = true
    if not ok2 then os.exit(1) end
end

if args.script then
    local code, err = loadfile(args.script, "t", env)
    if not code then
        io.stderr:write(tostring(err) .. "\n")
        os.exit(1)
    end
    local ok2 = runChunk(code, table.unpack(args.args or {}))
    ran_something = true
    if not ok2 then os.exit(1) end
end

if args.interactive or not ran_something then
    repl()
end
