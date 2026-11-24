-- Nexus Simple Shell
local colors  = require("colors")
local fs      = require("filesystem") --[[@as vfs]]
local process = require("process")
local scriptName = "sh"
local scriptArgs = {}

local function shell_value(name)
    if name == "#" then return tostring(#scriptArgs) end
    if name == "0" then return scriptName end
    if name:match("^%d+$") then return scriptArgs[tonumber(name)] or "" end
    if name == "?" then return os.getenv("?") or "0" end
    return os.getenv(name) or ""
end

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
    local word, glob_bytes, started = {}, {}, false
    local quote, escaped, word_unquoted_start = nil, false, false
    local i, len = 1, #line
    local function append_word(text, glob_eligible)
        word[#word + 1] = text
        for _ = 1, #text do glob_bytes[#glob_bytes + 1] = glob_eligible end
    end
    local function finish_word()
        if not started then return end
        local value = table.concat(word)
        if word_unquoted_start and value:sub(1, 1) == "~" then
            local home = home_path()
            if home then
                if value == "~" then value = home
                else value = (home == "/" and "" or home) .. value:sub(2) end
                local suffix_mask = {}
                for j = 2, #glob_bytes do suffix_mask[#suffix_mask + 1] = glob_bytes[j] end
                glob_bytes = {}
                -- The HOME prefix was inserted by tilde expansion and is literal.
                local suffix_length = #suffix_mask
                for _ = 1, #value - suffix_length do glob_bytes[#glob_bytes + 1] = false end
                for _, eligible in ipairs(suffix_mask) do glob_bytes[#glob_bytes + 1] = eligible end
            end
        end
        words[#words + 1] = { value = value, glob = glob_bytes }
        word, glob_bytes, started, word_unquoted_start = {}, {}, false, false
    end
    local function finish_segment()
        finish_word()
        segments[#segments + 1] = words
        words = {}
    end
    local function expansion_at(pos)
        local rest = line:sub(pos)
        local name, after = rest:match("^%$%{([%w_?#]+)%}()")
        if name then return shell_value(name), pos + after - 1 end
        name, after = rest:match("^%$([%d?#])()")
        if not name then name, after = rest:match("^%$([%a_][%w_]*)()") end
        if name then return shell_value(name), pos + after - 1 end
        return "$", pos + 1
    end
    while i <= len do
        local c = line:sub(i, i)
        if escaped then
            append_word(c, false)
            started, escaped = true, false
        elseif quote == "'" then
            if c == "'" then quote = nil else append_word(c, false) end
        elseif quote == '"' then
            if c == '"' then quote = nil
            elseif c == "\\" and i < len then
                i = i + 1
                append_word(line:sub(i, i), false)
            elseif c == "$" then
                local value, after = expansion_at(i)
                append_word(value, false)
                i = after - 1
            else append_word(c, false) end
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
            append_word(value, true)
            i = after - 1
        elseif c == "|" then finish_segment()
        elseif c:match("%s") then finish_word()
        elseif c == "#" and not started then break
        elseif c == ">" or c == "<" then
            finish_word()
            local op = c
            if c == ">" and line:sub(i + 1, i + 1) == ">" then
                op = ">>"
                i = i + 1
            end
            words[#words + 1] = { redirect = op }
        else
            if not started then
                local next_c = line:sub(i + 1, i + 1)
                word_unquoted_start = c == "~" and (next_c == "" or next_c == "/" or next_c == "|" or next_c:match("%s") ~= nil)
            end
            started = true
            append_word(c, true)
        end
        i = i + 1
    end
    if escaped then append_word("\\", false) end
    if quote then return {}, true end
    finish_segment()
    return segments, false
end

local function char_width(value, index)
    local byte = value:byte(index)
    if not byte then return 0 end
    if byte < 0x80 then return 1 end
    if byte >= 0xC2 and byte <= 0xDF then return 2 end
    if byte >= 0xE0 and byte <= 0xEF then return 3 end
    if byte >= 0xF0 and byte <= 0xF4 then return 4 end
    return 1
end

local function next_char(value, index)
    local width = char_width(value, index)
    if width == 0 then return nil, index end
    return value:sub(index, index + width - 1), index + width
end

local function class_end(value, mask, start)
    local i = start + 1
    if (value:sub(i, i) == "!" or value:sub(i, i) == "^") and mask[i] then i = i + 1 end
    if value:sub(i, i) == "]" then i = i + 1 end
    while i <= #value do
        if value:sub(i, i) == "]" and mask[i] then return i end
        i = i + char_width(value, i)
    end
end

local function compile_glob(value, mask)
    local tokens, has_wildcard = {}, false
    local i = 1
    while i <= #value do
        local c = value:sub(i, i)
        if mask[i] and c == "*" then
            if tokens[#tokens] == nil or tokens[#tokens].kind ~= "star" then
                tokens[#tokens + 1] = { kind = "star" }
            end
            has_wildcard = true
            i = i + 1
        elseif mask[i] and c == "?" then
            tokens[#tokens + 1] = { kind = "any" }
            has_wildcard = true
            i = i + 1
        elseif mask[i] and c == "[" then
            local ending = class_end(value, mask, i)
            if ending then
                local class_value, class_mask = value:sub(i + 1, ending - 1), {}
                for j = i + 1, ending - 1 do class_mask[#class_mask + 1] = mask[j] end
                tokens[#tokens + 1] = { kind = "class", value = class_value, mask = class_mask }
                has_wildcard = true
                i = ending + 1
            else
                local literal, after = next_char(value, i)
                tokens[#tokens + 1] = { kind = "literal", value = literal }
                i = after
            end
        else
            local literal, after = next_char(value, i)
            tokens[#tokens + 1] = { kind = "literal", value = literal }
            i = after
        end
    end
    return tokens, has_wildcard
end

local function class_matches(token, candidate)
    local class, mask = token.value, token.mask
    local first_char = class:sub(1, 1)
    local negate = (first_char == "!" or first_char == "^") and mask[1]
    local i = negate and 2 or 1
    local matched = false
    while i <= #class do
        local first, after_first = next_char(class, i)
        if after_first <= #class - 1 and class:sub(after_first, after_first) == "-" and mask[after_first] then
            local last, after_last = next_char(class, after_first + 1)
            if first and last and first <= candidate and candidate <= last then
                matched = true
            end
            i = after_last
        else
            if candidate == first then matched = true end
            i = after_first
        end
    end
    return negate and not matched or (not negate and matched)
end

local function glob_matches(name, tokens)
    local memo = {}
    local function match(token_index, name_index)
        local key = token_index .. ":" .. name_index
        if memo[key] ~= nil then return memo[key] end
        local token = tokens[token_index]
        if not token then
            local result = name_index > #name
            memo[key] = result
            return result
        end
        local result = false
        if token.kind == "star" then
            result = match(token_index + 1, name_index)
            if not result and name_index <= #name then
                local _, after = next_char(name, name_index)
                result = match(token_index, after)
            end
        elseif name_index <= #name then
            local candidate, after = next_char(name, name_index)
            if token.kind == "any" then
                result = match(token_index + 1, after)
            elseif token.kind == "class" then
                result = class_matches(token, candidate) and match(token_index + 1, after)
            elseif candidate == token.value then
                result = match(token_index + 1, after)
            end
        end
        memo[key] = result
        return result
    end
    return match(1, 1)
end

local function append_path_component(prefix, component)
    if prefix == "" then return component end
    if prefix == "/" then return "/" .. component end
    return prefix .. "/" .. component
end

local function expand_word(word)
    local value, mask = word.value, word.glob
    local has_pattern_byte = false
    for i = 1, #value do
        if mask[i] and (value:sub(i, i) == "*" or value:sub(i, i) == "?" or value:sub(i, i) == "[") then
            has_pattern_byte = true
            break
        end
    end
    if not has_pattern_byte then return { value } end
    local components, i = {}, 1
    while i <= #value do
        while value:sub(i, i) == "/" do i = i + 1 end
        if i <= #value then
            local start = i
            while i <= #value and value:sub(i, i) ~= "/" do i = i + 1 end
            local component, component_mask = value:sub(start, i - 1), {}
            for j = start, i - 1 do component_mask[#component_mask + 1] = mask[j] end
            local pattern, has_wildcard = compile_glob(component, component_mask)
            components[#components + 1] = { value = component, pattern = pattern, wildcard = has_wildcard }
        end
    end
    if #components == 0 then return { value } end
    local had_wildcard = false
    for _, component in ipairs(components) do
        if component.wildcard then had_wildcard = true; break end
    end
    if not had_wildcard then return { value } end

    local prefixes = { value:sub(1, 1) == "/" and "/" or "" }
    local wildcard_seen = false
    for _, component in ipairs(components) do
        local next_prefixes = {}
        if component.wildcard then
            wildcard_seen = true
            for _, prefix in ipairs(prefixes) do
                local resolve_ok, directory = pcall(fs.resolve, prefix == "" and "." or prefix)
                if not resolve_ok then directory = nil end
                local real = directory
                if directory then
                    local real_ok, real_path = pcall(fs.realPath, directory)
                    if not real_ok then directory = nil else real = real_path or directory end
                end
                local function can_list(path)
                    if not path then return false end
                    local ok, directory_attr = pcall(fs.isDirectory, path)
                    if not ok or not directory_attr then return false end
                    local can_ok, can_read = pcall(fs.can, path, "r")
                    if not can_ok or not can_read then return false end
                    local exec_ok, can_exec = pcall(fs.can, path, "x")
                    return exec_ok and can_exec
                end
                if can_list(directory) and (real == directory or can_list(real)) then
                    local listed, entries = pcall(fs.list, directory)
                    if listed and entries then
                        pcall(function()
                            for name in entries do
                                if (name:sub(1, 1) ~= "." or component.value:sub(1, 1) == ".")
                                    and glob_matches(name, component.pattern) then
                                    next_prefixes[#next_prefixes + 1] = append_path_component(prefix, name)
                                end
                            end
                        end)
                    end
                end
            end
        else
            for _, prefix in ipairs(prefixes) do
                local candidate = append_path_component(prefix, component.value)
                local exists = true
                if wildcard_seen then
                    local resolve_ok, resolved = pcall(fs.resolve, candidate)
                    local exists_ok, result = false, false
                    if resolve_ok then exists_ok, result = pcall(fs.exists, resolved) end
                    exists = exists_ok and result
                end
                if exists then
                    next_prefixes[#next_prefixes + 1] = candidate
                end
            end
        end
        prefixes = next_prefixes
        if #prefixes == 0 then break end
    end
    if #prefixes == 0 then return { value } end
    if value:sub(-1) == "/" then
        local directories = {}
        for _, candidate in ipairs(prefixes) do
            local resolve_ok, resolved = pcall(fs.resolve, candidate)
            local dir_ok, is_directory = false, false
            if resolve_ok then dir_ok, is_directory = pcall(fs.isDirectory, resolved) end
            if dir_ok and is_directory then
                directories[#directories + 1] = candidate:sub(-1) == "/" and candidate or (candidate .. "/")
            end
        end
        prefixes = directories
        if #prefixes == 0 then return { value } end
    end
    table.sort(prefixes)
    return prefixes
end

local function parse_redirections(segments)
    local parsed = {}
    for _, segment in ipairs(segments) do
        local command, redirects = {}, {}
        local i = 1
        while i <= #segment do
            local token = segment[i]
            if type(token) == "table" and token.redirect then
                local target = segment[i + 1]
                if type(target) ~= "table" or not target.value or target.value == "" then
                    return nil, "missing redirection target"
                end
                redirects[#redirects + 1] = { op = token.redirect, path = target.value, glob = target.glob }
                i = i + 2
            else
                command[#command + 1] = token
                i = i + 1
            end
        end
        parsed[#parsed + 1] = { args = command, redirects = redirects }
    end
    return parsed
end

local function is_standalone_assignment(stage)
    if #stage.args == 0 or #stage.redirects > 0 then return false end
    for _, word in ipairs(stage.args) do
        if not word.value:match("^[%a_][%w_]*=") then return false end
    end
    return true
end

local function expand_pipeline(parsed, location)
    for _, stage in ipairs(parsed) do
        local assignment_only = is_standalone_assignment(stage)
        local expanded = {}
        for _, word in ipairs(stage.args) do
            if assignment_only then
                expanded[#expanded + 1] = word.value
            else
                local matches = expand_word(word)
                for _, match in ipairs(matches) do expanded[#expanded + 1] = match end
            end
        end
        stage.args = expanded

        for _, redirect in ipairs(stage.redirects) do
            local matches = expand_word({ value = redirect.path, glob = redirect.glob })
            if #matches > 1 then
                io.stderr:write(location .. ": " .. redirect.path .. ": ambiguous redirect\n")
                return false
            end
            redirect.path = matches[1]
        end
    end
    return true
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

-- Interactive history: kept in memory for the line editor and appended to
-- ~/.sh_history as commands are entered.
local HISTORY_LIMIT = 200
local shell_history = {}

local function history_file()
    local home = home_path()
    if home then return fs.concat(home, ".sh_history") end
end

local function read_history()
    local entries = {}
    local path = history_file()
    if not path or not fs.exists(path) then return entries end
    local f = fs.open(path, "r")
    if not f then return entries end
    local data = f:read("*a") or ""
    f:close()
    for line in data:gmatch("[^\n]+") do entries[#entries + 1] = line end
    return entries
end

builtins["history"] = function(args)
    local path = history_file()
    if args[2] == "-c" then
        for i = #shell_history, 1, -1 do shell_history[i] = nil end
        if path then
            local f = fs.open(path, "w")
            if f then f:close() end
        end
        return 0
    end
    local entries = read_history()
    local first = math.max(1, #entries - HISTORY_LIMIT + 1)
    for i = first, #entries do
        io.write(string.format("%5d  %s\n", i, entries[i]))
    end
    return 0
end

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
    local code = tonumber(args[2] or os.getenv("?")) or 0
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
        { "history [-c]",      "コマンド履歴を表示する (-c で消去)" },
        { "help",              "このヘルプを表示する" },
    }
    for _, row in ipairs(list) do
        io.write(string.format("  %-22s %s\n", colors.green .. row[1] .. colors.reset, row[2]))
    end
    io.write("  Redirection: command < input, command > output, command >> output\n")
    io.write("  Example: cat < input.txt | cat > output.txt\n")
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

local function close_redirects(handles)
    for i = #handles, 1, -1 do
        if type(handles[i]) == "number" then
            pcall(fs.close, handles[i])
        else
            pcall(function() handles[i]:close() end)
        end
    end
end

local function open_redirects(redirects)
    local mapping, handles = {}, {}
    for _, redirect in ipairs(redirects) do
        local target_fd = redirect.op == "<" and 0 or 1
        local mode = redirect.op == "<" and "r" or (redirect.op == ">>" and "a" or "w")
        local open_ok, file, err = pcall(fs.open, redirect.path, mode)
        if not open_ok then
            close_redirects(handles)
            return nil, nil, redirect.path .. ": " .. tostring(file)
        end
        if not file then
            close_redirects(handles)
            return nil, nil, redirect.path .. ": " .. tostring(err or "open failed")
        end
        handles[#handles + 1] = file
        local fd = file:fd()
        if type(fd) ~= "number" or fd < 0 then
            close_redirects(handles)
            return nil, nil, redirect.path .. ": invalid file descriptor"
        end
        if fd < 3 then
            local safe_fd, dup_err = fs.dup(fd, 3)
            pcall(function() file:close() end)
            handles[#handles] = nil
            if type(safe_fd) ~= "number" or safe_fd < 0 then
                close_redirects(handles)
                return nil, nil, redirect.path .. ": " .. tostring(dup_err or "dup failed")
            end
            fd = safe_fd
            handles[#handles + 1] = fd
        end
        mapping[target_fd] = fd
    end
    return mapping, handles
end

local function run_builtin_redirected(args, redirects)
    local mapping, handles, err = open_redirects(redirects)
    if not mapping then
        io.stderr:write("sh: " .. tostring(err) .. "\n")
        return 1
    end
    local saved, absent = {}, {}
    local targets = {}
    for fd in pairs(mapping) do targets[#targets + 1] = fd end
    table.sort(targets)
    for _, fd in ipairs(targets) do
        local original, dup_err = fs.dup(fd, 3)
        if type(original) == "number" and original >= 0 then
            saved[fd] = original
        else
            -- A missing original descriptor is represented by dup failing with EBADF.
            absent[fd] = true
            if dup_err and not tostring(dup_err):lower():find("bad file descriptor", 1, true) then
                close_redirects(handles)
                for _, saved_fd in pairs(saved) do fs.close(saved_fd) end
                io.stderr:write("sh: cannot save fd " .. fd .. ": " .. tostring(dup_err) .. "\n")
                return 1
            end
        end
    end
    local applied, apply_err = {}, nil
    for _, fd in ipairs(targets) do
        local ok, result, dup2_err = pcall(fs.dup2, mapping[fd], fd)
        if not ok or result == nil or result == false or (type(result) == "number" and result < 0) then
            apply_err = ok and (dup2_err or "dup2 failed") or result
            break
        end
        applied[#applied + 1] = fd
    end
    local status
    if apply_err then
        io.stderr:write("sh: redirection: " .. tostring(apply_err) .. "\n")
        status = 1
    else
        local ok, result = pcall(builtins[args[1]], args)
        if not ok then
            io.stderr:write(args[1] .. ": " .. tostring(result) .. "\n")
            status = 1
        else status = result or 0 end
    end
    for i = #applied, 1, -1 do
        local fd = applied[i]
        if absent[fd] then
            pcall(fs.close, fd)
        else
            pcall(fs.dup2, saved[fd], fd)
        end
    end
    for _, fd in pairs(saved) do pcall(fs.close, fd) end
    close_redirects(handles)
    return status
end

---@param tokens string[]
---@return integer exitcode
local function run_command(tokens, redirects)
    if #tokens == 0 then return 0 end

    if tokens[1]:match("^[%a_][%w_]*=") and (not redirects or #redirects == 0) then
        local assignments = {}
        for i, token in ipairs(tokens) do
            local name, value = token:match("^([%a_][%w_]*)=(.*)$")
            if not name then break end
            assignments[i] = { name, value }
        end
        if #assignments == #tokens then
            for _, assignment in ipairs(assignments) do os.setenv(assignment[1], assignment[2]) end
            return 0
        end
    end

    local cmd = tokens[1]

    if builtins[cmd] then
        if redirects and #redirects > 0 then return run_builtin_redirected(tokens, redirects) end
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

    if redirects and #redirects > 0 then
        local mapping, handles, err = open_redirects(redirects)
        if not mapping then
            io.stderr:write("sh: " .. tostring(err) .. "\n")
            return 1
        end
        local child_args = {}
        for i = 2, #tokens do child_args[#child_args + 1] = tokens[i] end
        local pid, spawn_err, instance = process.spawn(path, child_args, mapping)
        close_redirects(handles)
        if not pid or pid == -1 then
            io.stderr:write(cmd .. ": " .. tostring(spawn_err or "spawn failed") .. "\n")
            return 1
        end
        if instance == nil then
            local proc = process.get(pid)
            instance = proc and proc.instance
        end
        local wait_err, status = process.wait(pid, instance)
        if wait_err then
            io.stderr:write(cmd .. ": process error: " .. tostring(wait_err) .. "\n")
            return 1
        end
        return type(status) == "number" and status or 0
    end
    return exec_external(path, tokens)
end

local function syntax_error(location, message)
    io.stderr:write(location .. ": syntax error: " .. message .. "\n")
    return 2, true
end

local function run_pipeline(segments, location)
    local parsed, parse_err = parse_redirections(segments)
    if not parsed then
        return syntax_error(location, parse_err)
    end
    for _, stage in ipairs(parsed) do
        if #stage.args == 0 and #stage.redirects > 0 then
            return syntax_error(location, "redirection without a command")
        end
    end
    if not expand_pipeline(parsed, location) then return 1 end
    if #parsed < 2 then
        local command = parsed[1] or { args = {}, redirects = {} }
        return run_command(command.args, command.redirects)
    end
    for _, stage in ipairs(parsed) do
        local args = stage.args
        if #args == 0 then
            return syntax_error(location, "missing command in pipeline")
        end
    end
    local stages = {}
    for i, stage in ipairs(parsed) do
        local args = stage.args
        if builtins[args[1]] then
            local child_args = { "--builtin", args[1] }
            for j = 2, #args do child_args[#child_args + 1] = args[j] end
            stages[i] = { path = "/usr/bin/sh.lua", args = child_args, label = args[1], redirects = stage.redirects }
        else
            local path = find_in_path(args[1])
            if not path then
                io.stderr:write(args[1] .. ": command not found\n")
                return 127
            end
            local child_args = {}
            for j = 2, #args do child_args[#child_args + 1] = args[j] end
            stages[i] = { path = path, args = child_args, label = args[1], redirects = stage.redirects }
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
        local redirs, handles, redirect_err = open_redirects(stage.redirects)
        if not redirs then
            failure = { label = stage.label, error = redirect_err }
            break
        end
        for fd, target_fd in pairs(redirs) do stdio[fd] = target_fd end
        local pid, err, instance = process.spawn(stage.path, stage.args, stdio)
        close_redirects(handles)
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

local function run_line(line, location)
    location = location or "sh"
    local segments, malformed = tokenize(line)
    if malformed then
        return syntax_error(location, "unmatched quote")
    end
    return run_pipeline(segments, location)
end

local function set_script_arguments(name, argv, first)
    scriptName = name
    scriptArgs = {}
    for i = first, #argv do scriptArgs[#scriptArgs + 1] = argv[i] end
end

local function run_script(file, name)
    local status, lineNumber = 0, 0
    os.setenv("?", "0")
    while true do
        local line, err = file:read("*L")
        if line == nil then
            if err then
                io.stderr:write("sh: " .. name .. ": " .. tostring(err) .. "\n")
                return 1
            end
            return status
        end
        lineNumber = lineNumber + 1
        line = line:gsub("\r?\n$", "")
        if line:find("%S") and not line:match("^%s*#") then
            local malformed
            status, malformed = run_line(line, name .. ":" .. lineNumber)
            os.setenv("?", tostring(status))
            if malformed then return status end
        end
    end
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
    if shell_args[2] == nil then
        io.stderr:write("sh: -c requires a command\n")
        os.exit(2)
        return
    end
    set_script_arguments(shell_args[3] or "sh", shell_args, 4)
    os.exit(run_line(shell_args[2]))
    return
elseif shell_args[1] == "-s" then
    set_script_arguments("sh", shell_args, 2)
    os.exit(run_script(io.stdin, "stdin"))
    return
elseif shell_args[1] and shell_args[1] ~= "-l" then
    local first = shell_args[1] == "--" and 2 or 1
    local path = shell_args[first]
    if not path or (first == 1 and path:sub(1, 1) == "-") then
        io.stderr:write("Usage: sh [-l] | sh -c command | sh -s [args...] | sh [--] script [args...]\n")
        os.exit(2)
        return
    end
    local opened, file, err = pcall(fs.open, path, "r")
    if not opened or not file then
        io.stderr:write("sh: " .. path .. ": " .. tostring(opened and err or file) .. "\n")
        os.exit(127)
        return
    end
    set_script_arguments(path, shell_args, first + 1)
    local status = run_script(file, path)
    file:close()
    os.exit(status)
    return
end

local last_exit = 0

-- Tab completion: command names for the first word, paths otherwise.
local function complete(before)
    local word = before:match("(%S*)$")
    local head = before:sub(1, #before - #word)
    local out, seen = {}, {}
    local function add(s)
        if not seen[s] then
            seen[s] = true
            out[#out + 1] = head .. s
        end
    end
    local function list(dir)
        local ok, iter = pcall(fs.list, dir)
        if ok and type(iter) == "function" then return iter end
        return function() return nil end
    end

    if not head:find("%S") and not word:find("/") then
        for name in pairs(builtins) do
            if name:sub(1, #word) == word then add(name) end
        end
        local path_env = os.getenv("PATH") or "/usr/ubin:/usr/bin:/bin"
        for dir in path_env:gmatch("[^:]+") do
            for name in list(dir) do
                name = name:gsub("/$", ""):gsub("%.lua$", "")
                if name:sub(1, #word) == word then add(name) end
            end
        end
        if #out == 1 then out[1] = out[1] .. " " end
        return out
    end

    local dir, base = word:match("^(.*/)([^/]*)$")
    if not dir then dir, base = "", word end
    local real = dir
    if real:sub(1, 2) == "~/" then real = (home_path() or "/") .. real:sub(2) end
    local cwd = process.cwd() or "/"
    local target = real == "" and cwd or (real:sub(1, 1) == "/" and real or fs.concat(cwd, real))
    target = target:gsub("(.)/+$", "%1")
    for name in list(target) do
        name = name:gsub("/$", "")
        if name:sub(1, #base) == base and (base:sub(1, 1) == "." or name:sub(1, 1) ~= ".") then
            add(dir .. name .. (fs.isDirectory(fs.concat(target, name)) and "/" or ""))
        end
    end
    if #out == 1 and not out[1]:find("/$") then out[1] = out[1] .. " " end
    return out
end

local function interactive()
    return io.isatty ~= nil and io.isatty(0) == true
end

local function remember(line)
    local path = history_file()
    if not path then return end
    local f = fs.open(path, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

do
    local entries = read_history()
    local first = math.max(1, #entries - HISTORY_LIMIT + 1)
    for i = first, #entries do shell_history[#shell_history + 1] = entries[i] end
    -- keep the file from growing without bound
    if #entries > HISTORY_LIMIT * 2 then
        local path = history_file()
        local f = path and fs.open(path, "w")
        if f then
            f:write(table.concat(shell_history, "\n") .. "\n")
            f:close()
        end
    end
end

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

-- An interactive shell leads its own process group, so Ctrl+C reaches the
-- commands it runs (they inherit the group) and not the processes that
-- started it. It catches SIGINT and SIGQUIT itself, like other Unix
-- shells: a caught signal reverts to the default in commands it starts.
if interactive() and process.signal then
    if process.setpgid then process.setpgid(0, 0) end
    process.signal(2, function() end)
    process.signal(3, function() end)
end

while true do
    io.write(get_prompt())

    local line
    if interactive() then
        line = io.read("*l", { history = shell_history, historyLimit = HISTORY_LIMIT, complete = complete })
    else
        line = io.read()
    end
    if not line then
        -- EOF (Ctrl+D)
        print("exit")
        os.exit(last_exit)
    end

    line = line:match("^%s*(.-)%s*$")

    if line ~= "" and interactive() then remember(line) end
    if line ~= "" then
        last_exit = run_line(line)
        if last_exit ~= nil then
            os.setenv("?", tostring(last_exit))
        end
    end

    coroutine.yield()
end
