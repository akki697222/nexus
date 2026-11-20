-- Nexus Simple Shell
local colors  = require("colors")
local fs      = require("filesystem") --[[@as vfs]]
local process = require("process")

local function expand_env(s, lookup)
    lookup = lookup or os.getenv
    return (s:gsub("%$({?)([%w_?]+)(}?)", function(open, key, close)
        if open == "{" then
            if close == "" then return "${" .. key end
            return lookup(key) or ""
        end
        return (lookup(key) or "") .. close
    end))
end

local function home_path()
    local home = os.getenv("HOME")
    if home and home ~= "" then return fs.concat(home) end
end

local function prompt_path()
    local cwd = process.cwd() or "/"
    local home = home_path()
    if cwd == home then return "~" end
    if home == "/" then return "~" .. cwd end
    if home and cwd:sub(1, #home + 1) == home .. "/" then
        return "~" .. cwd:sub(#home + 1)
    end
    return cwd
end

---@param line string
---@return string[][] segments, boolean malformed
local function tokenize(line)
    local segments, words = {}, {}
    local word, started = {}, false
    local quote, escaped, word_unquoted_start = nil, false, false
    local i, len = 1, #line
    local function finish_word()
        if not started then return end
        local value = table.concat(word)
        if word_unquoted_start and value:sub(1, 1) == "~" then
            local home = home_path()
            if home then
                if value == "~" then value = home
                else value = (home == "/" and "" or home) .. value:sub(2) end
            end
        end
        words[#words + 1] = value
        word, started, word_unquoted_start = {}, false, false
    end
    local function finish_segment()
        finish_word()
        segments[#segments + 1] = words
        words = {}
    end
    local function expansion_at(pos)
        local rest = line:sub(pos)
        local name, after = rest:match("^%$%{([%w_?]+)%}()")
        if name then return os.getenv(name) or "", pos + after - 1 end
        name, after = rest:match("^%$([%w_?]+)()")
        if name then return os.getenv(name) or "", pos + after - 1 end
        return "$", pos + 1
    end
    while i <= len do
        local c = line:sub(i, i)
        if escaped then
            word[#word + 1] = c
            started, escaped = true, false
        elseif quote == "'" then
            if c == "'" then quote = nil else word[#word + 1] = c end
        elseif quote == '"' then
            if c == '"' then quote = nil
            elseif c == "\\" and i < len then
                i = i + 1
                word[#word + 1] = line:sub(i, i)
            elseif c == "$" then
                local value, after = expansion_at(i)
                word[#word + 1] = value
                i = after - 1
            else word[#word + 1] = c end
        elseif c == "\\" then
            if not started then word_unquoted_start = false end
            started, escaped = true, true
        elseif c == "'" or c == '"' then
            if not started then word_unquoted_start = false end
            started, quote = true, c
        elseif c == "$" then
            local value, after = expansion_at(i)
            if not started then word_unquoted_start = false end
            started = true
            word[#word + 1] = value
            i = after - 1
        elseif c == "|" then finish_segment()
        elseif c:match("%s") then finish_word()
        elseif c == "#" and not started then break
        else
            if not started then
                local next_c = line:sub(i + 1, i + 1)
                word_unquoted_start = c == "~" and (next_c == "" or next_c == "/" or next_c == "|" or next_c:match("%s") ~= nil)
            end
            started = true
            word[#word + 1] = c
        end
        i = i + 1
    end
    if escaped then word[#word + 1] = "\\" end
    if quote then return {}, true end
    finish_segment()
    return segments, false
end

---@param cmd string
---@return string|nil
local function find_in_path(cmd)
    if cmd:sub(1,1) == "/" or cmd:sub(1,2) == "./" or cmd:sub(1,3) == "../" then
        if fs.exists(cmd) then return cmd end
        if fs.exists(cmd .. ".lua") then return cmd .. ".lua" end
        return nil
    end

    local path_env = os.getenv("PATH") or "/usr/ubin:/usr/bin:/bin"
    for dir in path_env:gmatch("[^:]+") do
        local full = dir .. "/" .. cmd
        if fs.exists(full) then return full end
        local full_lua = full .. ".lua"
        if fs.exists(full_lua) then return full_lua end
    end
    return nil
end

local builtins = {}

builtins["cd"] = function(args)
    local target = args[2] or home_path() or "/"
    local cwd, err = process.cwd(target)
    if not cwd then
        io.stderr:write("cd: " .. target .. ": " .. (err or "Cannot change directory") .. "\n")
        return 1
    end
    os.setenv("PWD", cwd)
    return 0
end

builtins["pwd"] = function(args)
    print(process.cwd())
    return 0
end

builtins["echo"] = function(args)
    local parts = {}
    local no_newline = false
    local i = 2
    if args[2] == "-n" then
        no_newline = true
        i = 3
    end
    while i <= #args do
        table.insert(parts, args[i])
        i = i + 1
    end
    local out = table.concat(parts, " ")
    if no_newline then
        io.write(out)
    else
        print(out)
    end
    return 0
end

builtins["exit"] = function(args)
    local code = tonumber(args[2]) or 0
    os.exit(code)
    return 0
end

builtins["export"] = function(args)
    for i = 2, #args do
        local k, v = args[i]:match("^([%w_]+)=(.*)$")
        if k then
            os.setenv(k, v)
        else

        end
    end
    return 0
end

builtins["unset"] = function(args)
    for i = 2, #args do
        os.setenv(args[i], nil)
    end
    return 0
end

builtins["env"] = function(args)
    local environ = process.getEnviron()
    if type(environ) == "table" then
        local keys = {}
        for k in pairs(environ) do table.insert(keys, k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            print(k .. "=" .. tostring(environ[k]))
        end
    end
    return 0
end

builtins["help"] = function(args)
    print(colors.bold .. "Nexus Shell - 組み込みコマンド一覧" .. colors.reset)
    local list = {
        { "cd [dir]",          "ディレクトリを変更する" },
        { "pwd",               "現在のディレクトリを表示する" },
        { "echo [-n] [args]",  "テキストを出力する" },
        { "export KEY=VAL",    "環境変数を設定する" },
        { "unset KEY",         "環境変数を削除する" },
        { "env",               "環境変数一覧を表示する" },
        { "exit [code]",       "シェルを終了する" },
        { "help",              "このヘルプを表示する" },
    }
    for _, row in ipairs(list) do
        io.write(string.format("  %-22s %s\n", colors.green .. row[1] .. colors.reset, row[2]))
    end
    return 0
end

---@param path string
---@param args string[]
---@return integer exitcode
local function exec_external(path, args)
    local exec_args = {}
    for i = 2, #args do
        table.insert(exec_args, args[i])
    end

    local pid, err = process.exec(path, exec_args)
    if not pid or pid == -1 then
        io.stderr:write(args[1] .. ": " .. (err or "exec failed") .. "\n")
        return 127
    end

    local wait_err, status = process.wait(pid)
    if wait_err then
        io.stderr:write(args[1] .. ": process error: " .. tostring(wait_err) .. "\n")
        return 1
    end
    return type(status) == "number" and status or 0
end

---@param tokens string[]
---@return integer exitcode
local function run_command(tokens)
    if #tokens == 0 then return 0 end

    local cmd = tokens[1]

    if builtins[cmd] then
        local ok, result = pcall(builtins[cmd], tokens)
        if not ok then
            io.stderr:write(cmd .. ": " .. tostring(result) .. "\n")
            return 1
        end
        return result or 0
    end

    local path = find_in_path(cmd)
    if not path then
        io.stderr:write(cmd .. ": command not found\n")
        return 127
    end

    return exec_external(path, tokens)
end

local function run_pipeline(segments)
    if #segments < 2 then return run_command(segments[1] or {}) end
    for _, args in ipairs(segments) do
        if #args == 0 then
            io.stderr:write("sh: syntax error: missing command in pipeline\n")
            return 2
        end
    end
    local stages = {}
    for i, args in ipairs(segments) do
        if builtins[args[1]] then
            local child_args = { "--builtin", args[1] }
            for j = 2, #args do child_args[#child_args + 1] = args[j] end
            stages[i] = { path = "/usr/bin/sh.lua", args = child_args, label = args[1] }
        else
            local path = find_in_path(args[1])
            if not path then
                io.stderr:write(args[1] .. ": command not found\n")
                return 127
            end
            local child_args = {}
            for j = 2, #args do child_args[#child_args + 1] = args[j] end
            stages[i] = { path = path, args = child_args, label = args[1] }
        end
    end
    local pipes = {}
    for i = 1, #stages - 1 do
        local rfd, wfd = fs.pipe()
        if type(rfd) ~= "number" or rfd < 0 or type(wfd) ~= "number" or wfd < 0 then
            if type(rfd) == "number" and rfd >= 0 then fs.close(rfd) end
            if type(wfd) == "number" and wfd >= 0 then fs.close(wfd) end
            for _, pipe in ipairs(pipes) do fs.close(pipe[1]); fs.close(pipe[2]) end
            io.stderr:write("sh: pipe: failed to create pipe\n")
            return 1
        end
        pipes[i] = { rfd, wfd }
    end
    local started, failure = {}, nil
    for i, stage in ipairs(stages) do
        local stdio = {}
        if i > 1 then stdio[0] = pipes[i - 1][1] end
        if i < #stages then stdio[1] = pipes[i][2] end
        local pid, err, instance = process.spawn(stage.path, stage.args, stdio)
        if not pid or pid == -1 then
            failure = { label = stage.label, error = err }
            break
        end
        if instance == nil then
            local proc = process.get(pid)
            instance = proc and proc.instance
        end
        started[#started + 1] = { pid = pid, instance = instance }
    end
    for _, pipe in ipairs(pipes) do fs.close(pipe[1]); fs.close(pipe[2]) end
    if failure then
        io.stderr:write(failure.label .. ": " .. tostring(failure.error or "spawn failed") .. "\n")
        for _, child in ipairs(started) do
            local proc = process.get(child.pid)
            if proc and proc.instance == child.instance then process.kill(child.pid) end
        end
        for _, child in ipairs(started) do process.wait(child.pid, child.instance) end
        return 1
    end
    local status = 0
    for i, child in ipairs(started) do
        local wait_err, child_status = process.wait(child.pid, child.instance)
        if wait_err then
            io.stderr:write(stages[i].label .. ": process error: " .. tostring(wait_err) .. "\n")
            if i == #started then status = 1 end
        elseif i == #started then
            status = type(child_status) == "number" and child_status or 0
        end
    end
    return status
end

local function run_line(line)
    local segments, malformed = tokenize(line)
    if malformed then
        io.stderr:write("sh: syntax error: unmatched quote\n")
        return 2
    end
    return run_pipeline(segments)
end

local function get_prompt()
    local cwd = prompt_path()
    local ps1 = os.getenv("PS1")
    if ps1 and ps1 ~= "" then
        return expand_env(ps1, function(key)
            if key == "PWD" then return cwd end
            return os.getenv(key)
        end)
    end

    local user    = os.getenv("USER") or os.getenv("USERNAME") or "user"
    local host    = os.getenv("HOSTNAME") or "nexus"
    local suffix  = (os.getenv("UID") == "0") and "# " or "$ "
    return colors.green .. user .. "@" .. host .. colors.reset
        .. ":" .. colors.bright_blue .. cwd .. colors.reset
        .. suffix
end

local shell_args = { ... }
if shell_args[1] == "--builtin" then
    local name = shell_args[2]
    local args = { name }
    for i = 3, #shell_args do args[#args + 1] = shell_args[i] end
    local builtin = builtins[name]
    local status = 127
    if builtin then
        local ok, result = pcall(builtin, args)
        if ok then status = result or 0
        else
            io.stderr:write(name .. ": " .. tostring(result) .. "\n")
            status = 1
        end
    end
    os.exit(status)
elseif shell_args[1] == "-c" then
    local line = shell_args[2] or ""
    os.exit(run_line(line))
end

local last_exit = 0

do
    local home = home_path()
    if home then
        if shell_args[1] == "-l" then
            local cwd, err = process.cwd(home)
            if not cwd then
                io.stderr:write("sh: " .. home .. ": " .. (err or "Cannot enter home directory") .. "\n")
            end
        end
        local profile = fs.concat(home, ".profile.lua")
        if fs.exists(profile) then
            local ok, err = pcall(dofile, profile)
            if not ok then
                io.stderr:write("sh: " .. profile .. ": " .. tostring(err) .. "\n")
            end
        end
    end
    os.setenv("PWD", process.cwd() or "/")
end

while true do
    io.write(get_prompt())

    local line = io.read()
    if not line then
        -- EOF (Ctrl+D)
        print("exit")
        os.exit(last_exit)
    end

    line = line:match("^%s*(.-)%s*$")

    if line ~= "" then
        last_exit = run_line(line)
        if last_exit ~= nil then
            os.setenv("?", tostring(last_exit))
        end
    end

    coroutine.yield()
end
