-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- stdin / stdout / stderr are resolved per process: each process inherits
-- its parent's streams (shell -> app); the terminal service installs the
-- defaults used by everything spawned by the kernel.

stdio = {}

local function fallback(name)
    if name == "stdin" then
        return { read = function() return nil end }
    end
    local level = name == "stderr" and log.warn or log.info
    local pending = ""
    return {
        write = function(_, s)
            pending = pending .. tostring(s)
            while true do
                local line, rest = pending:match("^([^\n]*)\n(.*)$")
                if not line then break end
                level("[%s] %s", name, line)
                pending = rest
            end
            return true
        end,
    }
end

local fallbacks = {}

local function stream_proxy(name)
    return setmetatable({}, {
        __index = function(_, key)
            local proc = process_manager.current_proc()
            local target = (proc and proc[name]) or process_manager["default_" .. name]
            if not target then
                fallbacks[name] = fallbacks[name] or fallback(name)
                target = fallbacks[name]
            end
            local fn = target[key]
            if type(fn) ~= "function" then return fn end
            return function(_, ...) return fn(target, ...) end
        end,
    })
end

stdin  = stream_proxy("stdin")
stdout = stream_proxy("stdout")
stderr = stream_proxy("stderr")

function print(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    stdout:write(table.concat(parts, "\t") .. "\n")
end

---In-memory pipe: write end and read end are the same object.
function stdio.pipe()
    local buf, closed = "", false
    local p = {}
    function p.write(_, s)
        buf = buf .. tostring(s)
        return true
    end
    function p.close() closed = true end
    function p.read(_, fmt)
        if fmt == nil then fmt = "a" end
        if type(fmt) == "string" then fmt = fmt:gsub("^%*", "") end
        if fmt == "a" then
            local out = buf
            buf = ""
            return out
        elseif fmt == "l" or fmt == "L" then
            if buf == "" then return nil end
            local nl = buf:find("\n", 1, true)
            local line
            if nl then
                line = buf:sub(1, fmt == "L" and nl or nl - 1)
                buf = buf:sub(nl + 1)
            else
                line, buf = buf, ""
            end
            return line
        elseif type(fmt) == "number" then
            if buf == "" and fmt > 0 then return nil end
            local out = buf:sub(1, fmt)
            buf = buf:sub(fmt + 1)
            return out
        end
        error("bad read format '" .. tostring(fmt) .. "'", 2)
    end
    return p
end
