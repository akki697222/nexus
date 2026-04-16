-- Nexus Simple Shell
local colors  = require("colors")
local fs      = require("filesystem") --[[@as vfs]]
local process = require("process")
local shell   = {}

-- ----------------------------------------------------------------
-- ユーティリティ
-- ----------------------------------------------------------------

--- 環境変数を展開する ($VAR / ${VAR})
local function expand_env(s)
    s = s:gsub("%${([%w_]+)}", function(k) return os.getenv(k) or "" end)
    s = s:gsub("%$([%w_]+)",   function(k) return os.getenv(k) or "" end)
    return s
end

--- PS1 プロンプト文字列を展開する
local function expand_prompt(ps1)
    return expand_env(ps1)
end

--- シンプルなコマンドライン字句解析
--- シングル/ダブルクォート対応、バックスラッシュエスケープ対応
---@param line string
---@return string[]
local function tokenize(line)
    local tokens = {}
    local i = 1
    local len = #line

    while i <= len do
        -- 空白スキップ
        while i <= len and line:sub(i,i):match("%s") do i = i + 1 end
        if i > len then break end

        local c = line:sub(i,i)
        local token = ""

        if c == "#" then
            -- コメント行
            break
        elseif c == "'" then
            -- シングルクォート: 内部を一切展開しない
            i = i + 1
            while i <= len and line:sub(i,i) ~= "'" do
                token = token .. line:sub(i,i)
                i = i + 1
            end
            i = i + 1 -- 閉じクォートをスキップ
        elseif c == '"' then
            -- ダブルクォート: 環境変数展開のみ行う
            i = i + 1
            while i <= len and line:sub(i,i) ~= '"' do
                local ch = line:sub(i,i)
                if ch == "\\" and i < len then
                    i = i + 1
                    token = token .. line:sub(i,i)
                elseif ch == "$" then
                    -- 変数展開
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
            i = i + 1 -- 閉じクォートをスキップ
        else
            -- 通常トークン (空白まで)
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

-- ----------------------------------------------------------------
-- PATH 検索
-- ----------------------------------------------------------------

---@param cmd string
---@return string|nil
local function find_in_path(cmd)
    -- 絶対パス / 相対パスはそのまま
    if cmd:sub(1,1) == "/" or cmd:sub(1,2) == "./" or cmd:sub(1,3) == "../" then
        if fs.exists(cmd) then return cmd end
        -- .lua 拡張子を補完
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

-- ----------------------------------------------------------------
-- 組み込みコマンド
-- ----------------------------------------------------------------

local builtins = {}

--- cd: ディレクトリ変更
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

--- pwd: カレントディレクトリ表示
builtins["pwd"] = function(args)
    print(process.cwd())
    return 0
end

--- echo: テキスト出力
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

--- exit: シェル終了
builtins["exit"] = function(args)
    local code = tonumber(args[2]) or 0
    os.exit(code)
    return 0
end

--- export: 環境変数設定
builtins["export"] = function(args)
    for i = 2, #args do
        local k, v = args[i]:match("^([%w_]+)=(.*)$")
        if k then
            os.setenv(k, v)
        else
            -- 値なし: 既存変数をそのままエクスポート (no-op)
        end
    end
    return 0
end

--- unset: 環境変数削除
builtins["unset"] = function(args)
    for i = 2, #args do
        os.setenv(args[i], nil)
    end
    return 0
end

--- env: 環境変数一覧表示
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

--- help: 組み込みコマンド一覧
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

-- ----------------------------------------------------------------
-- コマンド実行
-- ----------------------------------------------------------------

--- 外部コマンドを実行して終了を待つ
---@param path string
---@param args string[]
---@return integer exitcode
local function exec_external(path, args)
    -- process.exec はパスと引数テーブルを受け取る
    -- args[1] は argv[0] (コマンド名) なので args[2]以降を渡す
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

--- 1コマンドを解釈・実行する
---@param tokens string[]
---@return integer exitcode
local function run_command(tokens)
    if #tokens == 0 then return 0 end

    local cmd = tokens[1]

    -- 組み込みコマンド優先
    if builtins[cmd] then
        local ok, result = pcall(builtins[cmd], tokens)
        if not ok then
            io.stderr:write(cmd .. ": " .. tostring(result) .. "\n")
            return 1
        end
        return result or 0
    end

    -- 外部コマンド検索
    local path = find_in_path(cmd)
    if not path then
        io.stderr:write(cmd .. ": command not found\n")
        return 127
    end

    return exec_external(path, tokens)
end

-- ----------------------------------------------------------------
-- プロンプト表示
-- ----------------------------------------------------------------

local function get_prompt()
    local ps1 = os.getenv("PS1")
    if ps1 and ps1 ~= "" then
        return expand_prompt(ps1)
    end
    -- デフォルトプロンプト
    local user    = os.getenv("USER") or os.getenv("USERNAME") or "user"
    local host    = os.getenv("HOSTNAME") or "nexus"
    local cwd     = process.cwd() or "/"
    local home    = os.getenv("HOME") or "/root"
    -- ホームディレクトリを ~ に置換
    if cwd:sub(1, #home) == home then
        cwd = "~" .. cwd:sub(#home + 1)
    end
    local suffix  = (os.getenv("UID") == "0") and "# " or "$ "
    return colors.green .. user .. "@" .. host .. colors.reset
        .. ":" .. colors.bright_blue .. cwd .. colors.reset
        .. suffix
end

-- ----------------------------------------------------------------
-- メインループ
-- ----------------------------------------------------------------

local last_exit = 0

while true do
    -- プロンプト出力
    io.write(get_prompt())

    -- 入力読み込み
    local line = io.read()
    if not line then
        -- EOF (Ctrl+D)
        print("exit")
        os.exit(last_exit)
    end

    -- 前後の空白をトリム
    line = line:match("^%s*(.-)%s*$")

    if line ~= "" then
        -- トークン分割
        local tokens = tokenize(line)
        if #tokens > 0 then
            -- 実行
            last_exit = run_command(tokens)
            -- $? を更新
            os.setenv("?", tostring(last_exit))
        end
    end

    coroutine.yield()
end