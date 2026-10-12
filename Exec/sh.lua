-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- sh: interactive shell. Supports quoting, pipes (|), redirection (> >>),
-- builtins (cd exit help) and external commands found via PATH.
local proc = process_manager.current_proc()
proc.env = proc.env or {}
proc.env.PATH = proc.env.PATH or "System://Exec"

local function tokenize(line)
    local tokens, cur, quote = {}, nil, nil
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == quote then quote = nil else cur = (cur or "") .. c end
        elseif c == '"' or c == "'" then
            quote = c
            cur = cur or ""
        elseif c:match("%s") then
            if cur then tokens[#tokens + 1] = cur; cur = nil end
        elseif c == "|" then
            if cur then tokens[#tokens + 1] = cur; cur = nil end
            tokens[#tokens + 1] = { op = "|" }
        elseif c == ">" then
            if cur then tokens[#tokens + 1] = cur; cur = nil end
            if line:sub(i + 1, i + 1) == ">" then
                tokens[#tokens + 1] = { op = ">>" }
                i = i + 1
            else
                tokens[#tokens + 1] = { op = ">" }
            end
        else
            cur = (cur or "") .. c
        end
        i = i + 1
    end
    if quote then return nil, "unterminated quote" end
    if cur then tokens[#tokens + 1] = cur end
    return tokens
end

local function split_pipeline(tokens)
    local stages, cur = {}, { args = {} }
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if type(t) == "table" then
            if t.op == "|" then
                if #cur.args == 0 then return nil, "empty command before |" end
                stages[#stages + 1] = cur
                cur = { args = {} }
            else
                local target = tokens[i + 1]
                if type(target) ~= "string" then return nil, "missing file after " .. t.op end
                cur.redirect = { path = target, append = t.op == ">>" }
                i = i + 1
            end
        else
            cur.args[#cur.args + 1] = t
        end
        i = i + 1
    end
    if #cur.args == 0 then return nil, "empty command" end
    stages[#stages + 1] = cur
    return stages
end

local function find_command(name)
    if name:find("/", 1, true) or name:find(":", 1, true) then
        if not name:match("%.lua$") then name = name .. ".lua" end
        return fs.exists(name) and name or nil
    end
    for dir in (proc.env.PATH or ""):gmatch("[^;]+") do
        local path = dir:gsub("/$", "") .. "/" .. name .. ".lua"
        if fs.exists(path) then return path end
    end
    return nil
end

local builtins = {}

function builtins.cd(args)
    local target = fs.abspath(args[2] or "System://")
    if not target or not fs.is_dir(target) then
        stderr:write("cd: no such directory: " .. tostring(args[2]) .. "\n")
        return 1
    end
    proc.cwd = target
    return 0
end

function builtins.exit()
    process_manager.exit(0)
end

function builtins.help()
    print("builtins: cd exit help")
    local names = fs.list("System://Exec") or {}
    local cmds = {}
    for _, n in ipairs(names) do
        local c = n:match("^(.*)%.lua$")
        if c and c ~= "sh" then cmds[#cmds + 1] = c end
    end
    print("commands: " .. table.concat(cmds, " "))
    print("syntax:   cmd arg | cmd2 > file   (quotes allowed)")
    return 0
end

-- Wait for a foreground command; Ctrl+C (char 3) kills it.
local function wait_child(pid)
    while process_manager.get(pid) do
        -- only Ctrl+C is routed to us while the child owns the keyboard
        router.watch_input(proc.pid, function(e) return e.type == "key_down" and e.data[3] == 3 end)
        local ev = event.pull(nil, nil, function(e)
            return (e.type == "process_died" and e.pid == pid)
                or (e.type == "key_down" and e.data[3] == 3)
        end)
        router.unwatch_input(proc.pid)
        if ev.type == "process_died" then
            return ev.code or 1
        end
        process_manager.kill(pid, "interrupted")
        event.pull("process_died", 0, function(e) return e.pid == pid end)
        stderr:write("^C\n")
        return 130
    end
    return 1
end

-- Key presses are broadcast to every process, so the ones typed while a
-- foreground command ran (and were consumed by it) are also queued here.
-- Drop them so they are not replayed as shell input.
local function drain_input()
    local q = proc.event_queue
    for i = #q, 1, -1 do
        if q[i].type == "key_down" or q[i].type == "clipboard" then
            table.remove(q, i)
        end
    end
end

local function run_pipeline(stages)
    local input = nil          -- stdin of the next stage (nil = inherit)
    local last_code = 0
    for idx, stage in ipairs(stages) do
        local name = stage.args[1]
        local is_last = idx == #stages
        local out = nil
        if not is_last or stage.redirect then
            out = stdio.pipe()
        end

        if builtins[name] and #stages == 1 and not stage.redirect then
            last_code = builtins[name](stage.args) or 0
        else
            local path = (not builtins[name]) and find_command(name) or nil
            if not path then
                stderr:write(name .. ": command not found\n")
                last_code = 127
            else
                local args = {}
                for i = 2, #stage.args do args[#args + 1] = stage.args[i] end
                local ok, pid = pcall(process_manager.spawn, {
                    path = path, args = args, stdin = input, stdout = out,
                })
                if not ok then
                    stderr:write(name .. ": " .. tostring(pid) .. "\n")
                    last_code = 126
                else
                    last_code = wait_child(pid)
                    drain_input()
                end
            end
        end

        if stage.redirect and out then
            local ok, err = fs.write_file(stage.redirect.path, out:read("a"), stage.redirect.append)
            if not ok then
                stderr:write("redirect: " .. tostring(err) .. "\n")
                last_code = 1
            end
            out = nil
        end
        input = out
    end
    return last_code
end

-- Tab completion: command names, drive aliases and paths.
local function command_names()
    local names = { "cd", "exit", "help" }
    for _, n in ipairs(fs.list("System://Exec") or {}) do
        local c = n:match("^(.*)%.lua$")
        if c then names[#names + 1] = c end
    end
    return names
end

local function common_prefix(list)
    local p = list[1]
    for i = 2, #list do
        while list[i]:sub(1, #p) ~= p do p = p:sub(1, -2) end
    end
    return p
end

local function complete(prefix)
    local head, word = prefix:match("^(.*[%s|>])([^%s|>]*)$")
    if not head then head, word = "", prefix end
    local is_cmd = head:match("^%s*$") or head:match("|%s*$")
    local candidates, dir = {}, ""

    if is_cmd and not word:find("[/:]") then
        for _, n in ipairs(command_names()) do
            if n:sub(1, #word) == word then candidates[#candidates + 1] = n end
        end
    else
        local base = word
        local d = word:match("^(.*/)[^/]*$")
        if d then
            dir, base = d, word:sub(#d + 1)
        end
        if not d and not word:find(":", 1, true) then
            for alias in pairs(storage.list_volumes()) do
                if (alias .. "://"):sub(1, #word) == word then candidates[#candidates + 1] = alias .. "://" end
            end
        end
        for _, n in ipairs(fs.list(dir ~= "" and dir or ".") or {}) do
            if n:sub(1, #base) == base then
                candidates[#candidates + 1] = n .. (fs.is_dir(dir .. n) and "/" or "")
            end
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates)
    local common = common_prefix(candidates)
    if #candidates == 1 and not common:find("/$") and is_cmd then common = common .. " " end
    local is_alias_candidate = dir == "" and common:find("://", 1, true)
    return head .. (is_alias_candidate and "" or dir) .. common
end

print("Nexus shell. Type 'help'.")
while true do
    stdout:write(proc.cwd .. "> ")
    local line
    if proc.stdin == nil and term then
        line = term.read_line(complete)
    else
        line = stdin:read("l", complete)
    end
    if line == nil then break end
    if line:match("%S") then
        local tokens, err = tokenize(line)
        local stages
        if tokens then stages, err = split_pipeline(tokens) end
        if not stages then
            stderr:write("sh: " .. tostring(err) .. "\n")
        else
            local ok, e = pcall(run_pipeline, stages)
            if not ok then
                if type(e) == "table" and e.nexus_exit then error(e, 0) end
                stderr:write("sh: " .. tostring(e) .. "\n")
            end
        end
    end
end
