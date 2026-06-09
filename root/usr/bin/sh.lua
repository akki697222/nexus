-- Nexus Simple Shell
local colors  = require("colors")
local fs      = require("filesystem") --[[@as vfs]]
local process = require("process")

local function expand_env(s)
    s = s:gsub("%${([%w_]+)}", function(k) return os.getenv(k) or "" end)
    s = s:gsub("%$([%w_]+)",   function(k) return os.getenv(k) or "" end)
    return s
end

local function expand_prompt(ps1)
    local home = os.getenv("HOME") or ""
    local pwd  = os.getenv("PWD") or "/"

    local display_pwd = pwd
    if home ~= "" and pwd:sub(1, #home) == home then
        display_pwd = "~" .. pwd:sub(#home + 1)
    end

    ps1 = ps1:gsub("%${PWD}", display_pwd:gsub("%%", "%%%%"))
    ps1 = ps1:gsub("%$PWD",   display_pwd:gsub("%%", "%%%%"))

    return expand_env(ps1)
end

---@param line string
---@return string[]
local function tokenize(line)
    local tokens = {}
    local i = 1
    local len = #line

    while i <= len do
        while i <= len and line:sub(i,i):match("%s") do i = i + 1 end
        if i > len then break end

        local c = line:sub(i,i)
        local token = ""

        if c == "#" then
            break
        elseif c == "'" then
            i = i + 1
            while i <= len and line:sub(i,i) ~= "'" do
                token = token .. line:sub(i,i)
                i = i + 1
            end
            i = i + 1
        elseif c == '"' then
            i = i + 1
            while i <= len and line:sub(i,i) ~= '"' do
                local ch = line:sub(i,i)
                if ch == "\\" and i < len then
                    i = i + 1
                    token = token .. line:sub(i,i)
                elseif ch == "$" then
                    local rest = line:sub(i)
                    local var, endpos
                    var, endpos = rest:match("^%${([%w_]+)}()")
                    if var then
                        token = token .. (os.getenv(var) or "")
                        i = i + endpos - 1 - 1
                    else
                        var, endpos = rest:match("^%$([%w_]+)()")
                        if var then
                            token = token .. (os.getenv(var) or "")
                            i = i + endpos - 1 - 1
                        else
                            token = token .. ch
                        end
                    end
                else
                    token = token .. ch
                end
                i = i + 1
            end
            i = i + 1
        else
            while i <= len and not line:sub(i,i):match("%s") do
                local ch = line:sub(i,i)
                if ch == "\\" and i < len then
                    i = i + 1
                    token = token .. line:sub(i,i)
                else
                    token = token .. ch
                end
                i = i + 1
            end
            token = expand_env(token)
        end

        if token ~= "" then
            table.insert(tokens, token)
        end
    end

    return tokens
end

---@param cmd string
---@return string|nil
local function find_in_path(cmd)
    if cmd:sub(1,1) == "/" or cmd:sub(1,2) == "./" or cmd:sub(1,3) == "../" then
        if fs.exists(cmd) then return cmd end
        if fs.exists(cmd .. ".lua") then return cmd .. ".lua" end
        return nil
    end

    local path_env = os.getenv("PATH") or "/usr/bin:/bin"
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
    local target = args[2] or os.getenv("HOME") or "/"
    target = expand_env(target)
    if not fs.isDirectory(target) then
        io.stderr:write("cd: " .. target .. ": No such directory\n")
        return 1
    end
    process.cwd(target)
    os.setenv("PWD", process.cwd())
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

    local wait_err = process.wait(pid)
    if wait_err then
        io.stderr:write(args[1] .. ": process error: " .. tostring(wait_err) .. "\n")
        return 1
    end
    return 0
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

local function get_prompt()
    local ps1 = os.getenv("PS1")
    if ps1 and ps1 ~= "" then
        return expand_prompt(ps1)
    end

    local user    = os.getenv("USER") or os.getenv("USERNAME") or "user"
    local host    = os.getenv("HOSTNAME") or "nexus"
    local cwd     = process.cwd() or "/"
    local home    = os.getenv("HOME") or "/root"

    if cwd:sub(1, #home) == home then
        cwd = "~" .. cwd:sub(#home + 1)
    end
    local suffix  = (os.getenv("UID") == "0") and "# " or "$ "
    return colors.green .. user .. "@" .. host .. colors.reset
        .. ":" .. colors.bright_blue .. cwd .. colors.reset
        .. suffix
end

local last_exit = 0

do
    local home = os.getenv("HOME")
    if home and home ~= "" then
        local profile = fs.concat(home, ".profile.lua")
        if fs.exists(profile) then
            local ok, err = pcall(dofile, profile)
            if not ok then
                io.stderr:write("sh: " .. profile .. ": " .. tostring(err) .. "\n")
            end
        end
        if not os.getenv("PWD") or os.getenv("PWD") == "" then
            os.setenv("PWD", home or "/")
        end

    end
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
        local tokens = tokenize(line)
        if #tokens > 0 then
            last_exit = run_command(tokens)
            os.setenv("?", tostring(last_exit))
        end
    end

    coroutine.yield()
end