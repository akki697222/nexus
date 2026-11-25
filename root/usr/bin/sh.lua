-- Nexus Shell
--
-- A POSIX-style shell. Input is lexed into tokens and parsed into a syntax
-- tree one complete command at a time, then executed:
--   lists (; & newline), && and ||, pipelines and !, simple commands,
--   if / while / until / for / case, { } groups, ( ) subshells, functions,
--   redirections (< > >> >| <& >& &> &>> << <<-), ${name:-word} and the
--   rest of the parameter expansion family, $(...) and `...`, $((...)),
--   field splitting and pathname expansion.
-- Words are expanded when their command runs, not when it is parsed, so a
-- loop sees the current value of its variables. Whatever has to run in a
-- process of its own (a pipeline stage that is not a plain command, ( ),
-- $(...), &) is handed to a child "sh -c" together with the definitions of
-- the shell's functions.
local colors  = require("colors")
local fs      = require("filesystem") --[[@as vfs]]
local process = require("process")

local SHELL_PATH = "/usr/bin/sh.lua"
local scriptName = "sh"
local scriptArgs = {}
local last_status = 0
local last_bg_pid
local last_cmdsub_status
local opts = { errexit = false, nounset = false, xtrace = false, noglob = false }
local functions, function_order = {}, {}
local frames = {}            -- one per running function: locals to restore
local loop_depth, cond_depth, source_depth = 0, 0, 0
local errexit_exempt = false
local background = {}        -- pid -> instance of children started with &
local is_interactive = false
local capture                -- output of a builtin running inside $(...)
local MAX_CALL_DEPTH = 100
local HEREDOC_PIPE_LIMIT = 8000

local builtins = {}
local exec_node, run_text, run_argv, expand_fields, expand_string, expand_string_mask
local command_substitution, arith_eval

local function out(text)
    if capture then capture[#capture + 1] = text else io.write(text) end
end

local function set_status(status)
    last_status = status
    os.setenv("?", tostring(status))
end

local function valid_name(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function ifs_value()
    local ifs = os.getenv("IFS")
    if ifs == nil then return " \t\n" end
    return ifs
end

-- $? $# $0 $1.. $$ $! $- and named variables; nil when unset.
local function param_value(name)
    if name == "?" then return tostring(last_status) end
    if name == "#" then return tostring(#scriptArgs) end
    if name == "0" then return scriptName end
    if name == "$" then
        local pid = process.getCurrentPID and process.getCurrentPID()
        return tostring(pid or 0)
    end
    if name == "!" then return last_bg_pid and tostring(last_bg_pid) or nil end
    if name == "-" then
        local flags = ""
        if opts.errexit then flags = flags .. "e" end
        if opts.noglob then flags = flags .. "f" end
        if opts.nounset then flags = flags .. "u" end
        if opts.xtrace then flags = flags .. "x" end
        if is_interactive then flags = flags .. "i" end
        return flags
    end
    if name == "@" or name == "*" then
        if #scriptArgs == 0 then return nil end
        local sep = " "
        if name == "*" then sep = ifs_value():sub(1, 1) end
        return table.concat(scriptArgs, sep)
    end
    if name:match("^%d+$") then return scriptArgs[tonumber(name)] end
    return os.getenv(name)
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

------------------------------------------------------------------------
-- Pathname expansion
------------------------------------------------------------------------

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

-- Expands one field ({ value, glob = per-byte "may be a wildcard" mask })
-- against the filesystem. Unmatched patterns stay as they are.
local function glob_expand(word)
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

local function pathname_expand(field)
    if opts.noglob then return { field.value } end
    return glob_expand({ value = field.value, glob = field.mask })
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

------------------------------------------------------------------------
-- Lexer
------------------------------------------------------------------------
-- A word is a list of parts:
--   { t = "lit", s, q }            literal text; q = quoted (no globbing,
--                                   no field splitting)
--   { t = "tilde" }                a leading unquoted ~
--   { t = "param", name, op, arg, len, q }   $name, ${name op arg}, ${#name}
--   { t = "cmd", src, q }          $(src) or `src`
--   { t = "arith", expr, q }       $((expr)); expr is a word
-- word.plain is set when the word is a single unquoted literal: only such a
-- word can be a reserved word, an assignment or a function name.

local function syntax(message, line, incomplete)
    error({ sh_syntax = message, line = line, incomplete = incomplete or false }, 0)
end

local function expand_error(message, fatal)
    error({ sh_expand = message, fatal = fatal or false }, 0)
end

local OPERATORS = {
    "&>>", "<<-",
    "&&", "||", ";;", "&>", ">>", "<<", ">&", "<&", ">|",
    ";", "&", "|", "(", ")", "<", ">",
}
local REDIRECTIONS = {
    ["&>>"] = true, ["<<-"] = true, ["&>"] = true, [">>"] = true, ["<<"] = true,
    [">&"] = true, ["<&"] = true, [">|"] = true, ["<"] = true, [">"] = true,
}

local function ends_word(c)
    return c == "" or c == " " or c == "\t" or c == "\n" or c == ";" or c == "&"
        or c == "|" or c == "<" or c == ">" or c == "(" or c == ")"
end

-- Index of the backtick closing a command whose body starts at i.
local function skip_bq(src, i)
    while i <= #src do
        local c = src:sub(i, i)
        if c == "\\" then i = i + 2
        elseif c == "`" then return i
        else i = i + 1 end
    end
end

local find_close

-- Index of the " closing a double-quoted string whose body starts at i.
local function skip_dq(src, i)
    while i <= #src do
        local c = src:sub(i, i)
        if c == "\\" then i = i + 2
        elseif c == '"' then return i
        elseif c == "`" then
            local e = skip_bq(src, i + 1)
            if not e then return nil end
            i = e + 1
        elseif c == "$" and (src:sub(i + 1, i + 1) == "(" or src:sub(i + 1, i + 1) == "{") then
            local e = find_close(src, i + 2, src:sub(i + 1, i + 1) == "(" and ")" or "}")
            if not e then return nil end
            i = e + 1
        else i = i + 1 end
    end
end

-- Index of the `close` (")" or "}") ending a $( or ${ whose body starts at
-- i, skipping quoted text, escapes and nested constructs.
function find_close(src, i, close)
    local depth = 0
    while i <= #src do
        local c = src:sub(i, i)
        if c == "\\" then i = i + 2
        elseif c == "'" then
            local e = src:find("'", i + 1, true)
            if not e then return nil end
            i = e + 1
        elseif c == '"' then
            local e = skip_dq(src, i + 1)
            if not e then return nil end
            i = e + 1
        elseif c == "`" then
            local e = skip_bq(src, i + 1)
            if not e then return nil end
            i = e + 1
        elseif c == "$" and (src:sub(i + 1, i + 1) == "(" or src:sub(i + 1, i + 1) == "{") then
            local e = find_close(src, i + 2, src:sub(i + 1, i + 1) == "(" and ")" or "}")
            if not e then return nil end
            i = e + 1
        elseif close == ")" and c == "(" then
            depth = depth + 1
            i = i + 1
        elseif c == close then
            if depth == 0 then return i end
            depth = depth - 1
            i = i + 1
        else i = i + 1 end
    end
end

local scan_parts

-- The expansion starting with "$" at src[i]: its part (nil for a lone "$")
-- and the index after it.
local function scan_dollar(src, i, quoted, line)
    local n = src:sub(i + 1, i + 1)
    if n == "(" then
        local close = find_close(src, i + 2, ")")
        if not close then syntax("unterminated $(", line, true) end
        if src:sub(i + 2, i + 2) == "(" and src:sub(close - 1, close - 1) == ")"
            and find_close(src, i + 3, ")") == close - 1 then
            local expr = src:sub(i + 3, close - 2)
            return { t = "arith", expr = { parts = (scan_parts(expr, 1, "dq", true, line)) }, q = quoted }, close + 1
        end
        return { t = "cmd", src = src:sub(i + 2, close - 1), q = quoted }, close + 1
    elseif n == "{" then
        local close = find_close(src, i + 2, "}")
        if not close then syntax("unterminated ${", line, true) end
        local inner = src:sub(i + 2, close - 1)
        local part = { t = "param", q = quoted }
        if inner:sub(1, 1) == "#" and #inner > 1 then
            local name = inner:sub(2)
            if valid_name(name) or name:match("^%d+$") or name:match("^[@*#?$!%-]$") then
                part.name, part.len = name, true
                return part, close + 1
            end
        end
        local name, rest = inner:match("^([%a_][%w_]*)(.*)$")
        if not name then name, rest = inner:match("^(%d+)(.*)$") end
        if not name then name, rest = inner:match("^([@*#?$!%-])(.*)$") end
        if not name then syntax("bad substitution: ${" .. inner .. "}", line) end
        part.name = name
        if rest ~= "" then
            local op = rest:match("^(:[-=?+])") or rest:match("^([-=?+])") or rest:match("^(##)")
                or rest:match("^(#)") or rest:match("^(%%%%)") or rest:match("^(%%)")
            if not op then syntax("bad substitution: ${" .. inner .. "}", line) end
            part.op = op
            part.arg = { parts = (scan_parts(rest:sub(#op + 1), 1, "arg", quoted, line)) }
        end
        return part, close + 1
    end
    local name = src:match("^[%a_][%w_]*", i + 1)
    if name then return { t = "param", name = name, q = quoted }, i + 1 + #name end
    if n ~= "" and n:match("^[%d@*#?$!%-]$") then
        return { t = "param", name = n, q = quoted }, i + 2
    end
    return nil, i + 1
end

-- Builds word parts from src starting at i. mode:
--   "word" a shell word, stopping at an unquoted metacharacter
--   "arg"  a ${...} operand (quotes and escapes, read to the end)
--   "dqq"  the inside of a "..." string
--   "dq"   here-document bodies and arithmetic: only $, ` and \ are special
-- force_q marks every part quoted. Returns the parts, the index of the first
-- unread character and the number of newlines consumed.
function scan_parts(src, i, mode, force_q, line)
    local parts = {}
    local newlines = 0
    local function lit(text, q)
        q = q or force_q
        local last = parts[#parts]
        if last and last.t == "lit" and last.q == q then last.s = last.s .. text
        else parts[#parts + 1] = { t = "lit", s = text, q = q } end
    end
    local start = i
    local double = mode == "dq" or mode == "dqq"
    local escapable = mode == "dqq" and '$`"\\' or '$`\\'
    while i <= #src do
        local c = src:sub(i, i)
        if mode == "word" and ends_word(c) then break end
        if c == "\\" then
            local n = src:sub(i + 1, i + 1)
            if n == "\n" then
                newlines = newlines + 1
                i = i + 2
            elseif double then
                if n ~= "" and escapable:find(n, 1, true) then lit(n, true); i = i + 2
                else lit("\\", true); i = i + 1 end
            elseif n == "" then
                lit("\\", true)
                i = i + 1
            else
                lit(n, true)
                i = i + 2
            end
        elseif c == "'" and not double then
            local e = src:find("'", i + 1, true)
            if not e then syntax("unterminated quote", line, true) end
            local text = src:sub(i + 1, e - 1)
            for _ in text:gmatch("\n") do newlines = newlines + 1 end
            lit(text, true)
            i = e + 1
        elseif c == '"' and not double then
            local e = skip_dq(src, i + 1)
            if not e then syntax("unterminated quote", line, true) end
            local inner, _, nl = scan_parts(src:sub(i + 1, e - 1), 1, "dqq", true, line)
            newlines = newlines + nl
            if #inner == 0 then lit("", true) end
            for _, p in ipairs(inner) do
                if p.t == "lit" then lit(p.s, true) else parts[#parts + 1] = p end
            end
            i = e + 1
        elseif c == "`" then
            local e = skip_bq(src, i + 1)
            if not e then syntax("unterminated `", line, true) end
            local body = src:sub(i + 1, e - 1):gsub("\\([$`\\])", "%1")
            parts[#parts + 1] = { t = "cmd", src = body, q = force_q }
            i = e + 1
        elseif c == "$" then
            local part, after = scan_dollar(src, i, force_q, line)
            if part then parts[#parts + 1] = part else lit("$", false) end
            i = after
        else
            if c == "\n" then newlines = newlines + 1 end
            if c == "~" and i == start and mode == "word" and (src:sub(i + 1, i + 1) == "/"
                or ends_word(src:sub(i + 1, i + 1))) then
                parts[#parts + 1] = { t = "tilde" }
            else
                lit(c, false)
            end
            i = i + 1
        end
    end
    return parts, i, newlines
end

local function make_word(parts)
    local w = { parts = parts }
    if #parts == 1 and parts[1].t == "lit" and not parts[1].q then w.plain = parts[1].s end
    return w
end

local function new_lexer(src, line)
    return { src = src, pos = 1, line = line or 1, pending = {}, want_delim = nil }
end

-- Reads the bodies of the here-documents opened on the line just ended.
local function read_heredocs(L)
    local src = L.src
    for _, hd in ipairs(L.pending) do
        local body = {}
        hd.raw_s = L.pos
        while true do
            if L.pos > #src then
                syntax("here-document delimited by end of file (wanted `" .. hd.delim .. "')", L.line, true)
            end
            local nl = src:find("\n", L.pos, true)
            local text = src:sub(L.pos, (nl or (#src + 1)) - 1)
            L.pos = (nl or #src) + 1
            L.line = L.line + 1
            if hd.strip then text = (text:gsub("^\t+", "")) end
            if text == hd.delim then break end
            body[#body + 1] = text .. "\n"
        end
        hd.body = table.concat(body)
        hd.raw = src:sub(hd.raw_s, L.pos - 1)
    end
    L.pending = {}
end

local function next_token(L)
    local src = L.src
    while true do
        local c = src:sub(L.pos, L.pos)
        if c == " " or c == "\t" then
            L.pos = L.pos + 1
        elseif c == "\\" and src:sub(L.pos + 1, L.pos + 1) == "\n" then
            L.pos = L.pos + 2
            L.line = L.line + 1
        elseif c == "#" then
            L.pos = src:find("\n", L.pos, true) or (#src + 1)
        else
            break
        end
    end
    local s, line = L.pos, L.line
    if s > #src then
        if L.want_delim then syntax("missing here-document delimiter", line, true) end
        if #L.pending > 0 then read_heredocs(L) end
        return { k = "eof", s = s, e = s - 1, line = line }
    end
    local c = src:sub(s, s)
    if c == "\n" then
        L.pos = s + 1
        L.line = L.line + 1
        if L.want_delim then syntax("missing here-document delimiter", line) end
        local tok = { k = "op", v = "nl", s = s, e = s, line = line }
        if #L.pending > 0 then read_heredocs(L) end
        return tok
    end
    for _, op in ipairs(OPERATORS) do
        if src:sub(s, s + #op - 1) == op then
            L.pos = s + #op
            if REDIRECTIONS[op] then
                local tok = { k = "redir", op = op, s = s, e = L.pos - 1, line = line }
                if op == "<<" or op == "<<-" then L.want_delim = tok end
                return tok
            end
            return { k = "op", v = op, s = s, e = L.pos - 1, line = line }
        end
    end
    local parts, after, newlines = scan_parts(src, s, "word", false, line)
    L.pos = after
    L.line = L.line + newlines
    local w = make_word(parts)
    local n = src:sub(after, after)
    if w.plain and w.plain:match("^%d+$") and (n == "<" or n == ">") then
        -- IO_NUMBER: digits directly followed by a redirection operator
        local tok = next_token(L)
        tok.fd = tonumber(w.plain)
        tok.s = s
        return tok
    end
    if L.want_delim then
        local hd, text, quoted = L.want_delim, {}, false
        L.want_delim = nil
        for _, p in ipairs(parts) do
            if p.q then quoted = true end
            if p.t == "lit" then text[#text + 1] = p.s
            elseif p.t == "param" then text[#text + 1] = "$" .. p.name end
        end
        hd.heredoc = { delim = table.concat(text), quoted = quoted, strip = hd.op == "<<-" }
        L.pending[#L.pending + 1] = hd.heredoc
    end
    return { k = "word", w = w, s = s, e = after - 1, line = line }
end

------------------------------------------------------------------------
-- Parser
------------------------------------------------------------------------
-- Nodes:
--   list     { items = { { node, bg } } }
--   andor    { first, rest = { { op = "&&"|"||", node } } }
--   pipeline { cmds, bang }
--   simple   { assigns = { { name, value } }, words, redirs }
--   brace / subshell { body }, if { clauses = { { cond, body } }, else_body },
--   while / until { cond, body }, for { var, words|nil, body },
--   case { word, items = { { patterns, body } } }      (all with redirs)
--   funcdef  { name, body }
-- Every node remembers the source text it came from (s .. e) so it can be
-- handed to a child shell.

local Parser = {}
Parser.__index = Parser

local COMPOUND = { ["{"] = true, ["if"] = true, ["while"] = true, ["until"] = true, ["for"] = true, ["case"] = true }
local CLOSERS = { ["}"] = true, ["then"] = true, ["else"] = true, ["elif"] = true, ["fi"] = true,
    ["do"] = true, ["done"] = true, ["esac"] = true }
local RESERVED = { ["!"] = true, ["{"] = true, ["}"] = true, ["case"] = true, ["do"] = true,
    ["done"] = true, ["elif"] = true, ["else"] = true, ["esac"] = true, ["fi"] = true, ["for"] = true,
    ["function"] = true, ["if"] = true, ["in"] = true, ["then"] = true, ["until"] = true, ["while"] = true }

local function new_parser(L)
    return setmetatable({ L = L, ahead = {}, last = nil, heredocs = {} }, Parser)
end

function Parser:peek(n)
    n = n or 1
    while #self.ahead < n do self.ahead[#self.ahead + 1] = next_token(self.L) end
    return self.ahead[n]
end

function Parser:take()
    local t = self:peek(1)
    table.remove(self.ahead, 1)
    self.last = t
    return t
end

local function is_op(t, v) return t.k == "op" and t.v == v end
local function is_kw(t, v) return t.k == "word" and t.w.plain == v end

local function describe(t)
    if t.k == "eof" then return "end of file" end
    if t.k == "op" then return t.v == "nl" and "newline" or ("`" .. t.v .. "'") end
    if t.k == "redir" then return "`" .. t.op .. "'" end
    return "`" .. (t.w.plain or "word") .. "'"
end

function Parser:fail(t, message)
    t = t or self:peek()
    if t.k == "eof" then syntax("unexpected end of file", t.line, true) end
    syntax(message or ("unexpected " .. describe(t)), t.line)
end

function Parser:linebreak()
    while is_op(self:peek(), "nl") do self:take() end
end

function Parser:expect_kw(v)
    local t = self:peek()
    if not is_kw(t, v) then self:fail(t, "expected `" .. v .. "' before " .. describe(t)) end
    return self:take()
end

function Parser:at_stop(stops)
    local t = self:peek()
    if t.k == "eof" then return true end
    if t.k == "op" then return stops[t.v] == true end
    return t.k == "word" and t.w.plain ~= nil and stops[t.w.plain] == true
end

function Parser:begin()
    return { s = self:peek().s, hd = #self.heredocs + 1 }
end

function Parser:finish(node, mark)
    node.s, node.e = mark.s, self.last.e
    node.src_text = self.L.src
    node.hd_list, node.hd_from, node.hd_to = self.heredocs, mark.hd, #self.heredocs
    return node
end

-- One line's worth of commands; nil at the end of the input.
function Parser:complete_command()
    self:linebreak()
    if self:peek().k == "eof" then return nil end
    local items = {}
    while true do
        local node = self:and_or()
        local t = self:peek()
        if is_op(t, ";") or is_op(t, "&") then
            self:take()
            items[#items + 1] = { node = node, bg = t.v == "&" }
            local n = self:peek()
            if is_op(n, "nl") then self:take(); break end
            if n.k == "eof" then break end
        elseif is_op(t, "nl") then
            self:take()
            items[#items + 1] = { node = node }
            break
        elseif t.k == "eof" then
            items[#items + 1] = { node = node }
            break
        else
            self:fail(t)
        end
    end
    return { type = "list", items = items }
end

-- The body of a compound command, up to one of `stops`.
function Parser:compound_list(stops)
    self:linebreak()
    if self:at_stop(stops) then self:fail() end
    local items = {}
    repeat
        local node = self:and_or()
        local t = self:peek()
        local bg = false
        if is_op(t, ";") or is_op(t, "&") then
            bg = t.v == "&"
            self:take()
        elseif not is_op(t, "nl") and not self:at_stop(stops) then
            self:fail(t)
        end
        items[#items + 1] = { node = node, bg = bg }
        self:linebreak()
    until self:at_stop(stops)
    return { type = "list", items = items }
end

function Parser:and_or()
    local mark = self:begin()
    local first = self:pipeline()
    local rest = {}
    while is_op(self:peek(), "&&") or is_op(self:peek(), "||") do
        local op = self:take().v
        self:linebreak()
        rest[#rest + 1] = { op = op, node = self:pipeline() }
    end
    if #rest == 0 then return first end
    return self:finish({ type = "andor", first = first, rest = rest }, mark)
end

function Parser:pipeline()
    local mark = self:begin()
    local bang = false
    if is_kw(self:peek(), "!") then
        self:take()
        bang = true
    end
    local cmds = { self:command() }
    while is_op(self:peek(), "|") do
        self:take()
        self:linebreak()
        cmds[#cmds + 1] = self:command()
    end
    if #cmds == 1 and not bang then return cmds[1] end
    return self:finish({ type = "pipeline", cmds = cmds, bang = bang }, mark)
end

function Parser:command()
    local mark = self:begin()
    local t = self:peek()
    local node
    if is_op(t, "(") then
        node = self:subshell()
    elseif t.k == "word" and t.w.plain then
        local p = t.w.plain
        if COMPOUND[p] then
            node = self:compound()
        elseif p == "function" then
            return self:function_def(true)
        elseif CLOSERS[p] then
            self:fail(t)
        elseif valid_name(p) and is_op(self:peek(2), "(") then
            return self:function_def(false)
        end
    end
    if not node then return self:simple_command() end
    node.redirs = self:redirect_list()
    return self:finish(node, mark)
end

function Parser:subshell()
    local open = self:take()
    local body = self:compound_list({ [")"] = true })
    local close = self:peek()
    if not is_op(close, ")") then self:fail(close) end
    self:take()
    return { type = "subshell", body = body, inner_s = open.e + 1, inner_e = close.s - 1 }
end

function Parser:compound()
    local p = self:take().w.plain
    if p == "{" then
        local node = { type = "brace", body = self:compound_list({ ["}"] = true }) }
        self:expect_kw("}")
        return node
    elseif p == "if" then
        local node = { type = "if", clauses = {} }
        while true do
            local cond = self:compound_list({ ["then"] = true })
            self:expect_kw("then")
            local body = self:compound_list({ ["elif"] = true, ["else"] = true, ["fi"] = true })
            node.clauses[#node.clauses + 1] = { cond = cond, body = body }
            if is_kw(self:peek(), "elif") then self:take() else break end
        end
        if is_kw(self:peek(), "else") then
            self:take()
            node.else_body = self:compound_list({ ["fi"] = true })
        end
        self:expect_kw("fi")
        return node
    elseif p == "while" or p == "until" then
        local node = { type = p }
        node.cond = self:compound_list({ ["do"] = true })
        self:expect_kw("do")
        node.body = self:compound_list({ ["done"] = true })
        self:expect_kw("done")
        return node
    elseif p == "for" then
        local nt = self:take()
        if nt.k ~= "word" or not valid_name(nt.w.plain) then self:fail(nt, "invalid for loop variable") end
        local node = { type = "for", var = nt.w.plain }
        if is_op(self:peek(), ";") then
            self:take()
            self:linebreak()
        else
            self:linebreak()
            if is_kw(self:peek(), "in") then
                self:take()
                node.words = {}
                while self:peek().k == "word" do node.words[#node.words + 1] = self:take().w end
                local sep = self:peek()
                if is_op(sep, ";") or is_op(sep, "nl") then self:take() else self:fail(sep) end
                self:linebreak()
            end
        end
        self:expect_kw("do")
        node.body = self:compound_list({ ["done"] = true })
        self:expect_kw("done")
        return node
    else -- case
        local wt = self:take()
        if wt.k ~= "word" then self:fail(wt) end
        local node = { type = "case", word = wt.w, items = {} }
        self:linebreak()
        self:expect_kw("in")
        while true do
            self:linebreak()
            local t = self:peek()
            if is_kw(t, "esac") then
                self:take()
                break
            end
            if t.k == "eof" then self:fail(t) end
            if is_op(t, "(") then self:take() end
            local patterns = {}
            while true do
                local pt = self:take()
                if pt.k ~= "word" then self:fail(pt) end
                patterns[#patterns + 1] = pt.w
                if is_op(self:peek(), "|") then self:take() else break end
            end
            local close = self:take()
            if not is_op(close, ")") then self:fail(close) end
            self:linebreak()
            local body
            local nx = self:peek()
            if is_op(nx, ";;") or is_kw(nx, "esac") then
                body = { type = "list", items = {} }
            else
                body = self:compound_list({ [";;"] = true, ["esac"] = true })
            end
            node.items[#node.items + 1] = { patterns = patterns, body = body }
            if is_op(self:peek(), ";;") then
                self:take()
            elseif not is_kw(self:peek(), "esac") then
                self:fail()
            end
        end
        return node
    end
end

function Parser:function_def(keyword)
    local mark = self:begin()
    if keyword then self:take() end
    local nt = self:take()
    if nt.k ~= "word" or not valid_name(nt.w.plain) or RESERVED[nt.w.plain] then
        self:fail(nt, "invalid function name")
    end
    if is_op(self:peek(), "(") then
        self:take()
        local close = self:take()
        if not is_op(close, ")") then self:fail(close) end
    elseif not keyword then
        self:fail()
    end
    self:linebreak()
    local bt = self:peek()
    if not ((bt.k == "word" and COMPOUND[bt.w.plain or ""]) or is_op(bt, "(")) then
        self:fail(bt, "function body must be a compound command")
    end
    local body = self:command()
    return self:finish({ type = "funcdef", name = nt.w.plain, body = body }, mark)
end

-- NAME=value as the leading part of an unquoted word.
local function assignment_of(w)
    local first = w.parts[1]
    if not first or first.t ~= "lit" or first.q then return nil end
    local name, rest = first.s:match("^([%a_][%w_]*)=(.*)$")
    if not name then return nil end
    local parts = {}
    if rest ~= "" then parts[1] = { t = "lit", s = rest, q = false } end
    for i = 2, #w.parts do parts[#parts + 1] = w.parts[i] end
    return name, { parts = parts }
end

function Parser:redirect(t)
    local target = self:peek()
    if target.k ~= "word" then
        syntax("missing redirection target", target.line, target.k == "eof")
    end
    self:take()
    local r = { op = t.op, fd = t.fd, target = target.w, line = t.line }
    if t.heredoc then
        r.heredoc = t.heredoc
        self.heredocs[#self.heredocs + 1] = t.heredoc
    end
    return r
end

function Parser:redirect_list()
    local list = {}
    while self:peek().k == "redir" do list[#list + 1] = self:redirect(self:take()) end
    return list
end

function Parser:simple_command()
    local mark = self:begin()
    local node = { type = "simple", assigns = {}, words = {}, redirs = {}, line = self:peek().line }
    while true do
        local t = self:peek()
        if t.k == "redir" then
            self:take()
            node.redirs[#node.redirs + 1] = self:redirect(t)
        elseif t.k == "word" then
            self:take()
            local name, value
            if #node.words == 0 then name, value = assignment_of(t.w) end
            if name then
                node.assigns[#node.assigns + 1] = { name = name, value = value }
            else
                node.words[#node.words + 1] = t.w
            end
        else
            break
        end
    end
    if #node.words == 0 and #node.assigns == 0 then
        if #node.redirs > 0 then syntax("redirection without a command", node.line) end
        self:fail()
    end
    return self:finish(node, mark)
end

-- Source text of a node for a child shell: its own text plus the bodies of
-- any here-documents it opened that lie past it.
local function node_src(node, s, e)
    s, e = s or node.s, e or node.e
    local text = node.src_text:sub(s, e)
    if node.hd_list then
        for i = node.hd_from, node.hd_to do
            local hd = node.hd_list[i]
            if hd and hd.raw_s and hd.raw_s > e then text = text .. "\n" .. hd.raw end
        end
    end
    return text
end

------------------------------------------------------------------------
-- Arithmetic: $(( )) with C operators and precedence, integers only
------------------------------------------------------------------------

local ARITH_OPS = {
    "<<=", ">>=",
    "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--",
    "+", "-", "*", "/", "%", "<", ">", "&", "|", "^", "~", "!", "(", ")", "?", ":", "=", ",",
}
local ARITH_LEVELS = {
    { "||" }, { "&&" }, { "|" }, { "^" }, { "&" }, { "==", "!=" }, { "<", "<=", ">", ">=" },
    { "<<", ">>" }, { "+", "-" }, { "*", "/", "%" },
}
local ARITH_ASSIGN = { ["="] = true, ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
    ["%="] = true, ["<<="] = true, [">>="] = true, ["&="] = true, ["|="] = true, ["^="] = true }

local function arith_tokens(expr)
    local toks, i = {}, 1
    while i <= #expr do
        local c = expr:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("%d") then
            local num = expr:match("^0[xX]%x+", i) or expr:match("^%d+", i)
            local value
            if num:match("^0[xX]") then value = tonumber(num:sub(3), 16)
            elseif num:match("^0%d") then value = tonumber(num, 8)
            else value = tonumber(num) end
            if not value or expr:sub(i + #num, i + #num):match("[%w_]") then
                expand_error("invalid number in arithmetic expression: " .. expr:match("^[%w_]+", i))
            end
            toks[#toks + 1] = { k = "num", v = value }
            i = i + #num
        elseif c:match("[%a_]") then
            local name = expr:match("^[%a_][%w_]*", i)
            toks[#toks + 1] = { k = "name", v = name }
            i = i + #name
        else
            local found
            for _, op in ipairs(ARITH_OPS) do
                if expr:sub(i, i + #op - 1) == op then found = op; break end
            end
            if not found then expand_error("arithmetic syntax error near `" .. expr:sub(i) .. "'") end
            toks[#toks + 1] = { k = "op", v = found }
            i = i + #found
        end
    end
    toks[#toks + 1] = { k = "end" }
    return toks
end

local arith_depth = 0

function arith_eval(expr)
    local toks = arith_tokens(expr)
    local pos, noeval = 1, 0
    local function peek() return toks[pos] end
    local function take() pos = pos + 1; return toks[pos - 1] end
    local function is(v) local t = toks[pos]; return t.k == "op" and t.v == v end

    local function var_value(name)
        local v = os.getenv(name)
        if v == nil or v == "" then return 0 end
        local n = math.tointeger(tonumber(v))
        if n then return n end
        if arith_depth > 16 then expand_error(name .. ": expression recursion level exceeded") end
        arith_depth = arith_depth + 1
        local ok, result = pcall(arith_eval, v)
        arith_depth = arith_depth - 1
        if not ok then error(result, 0) end
        return result
    end
    local function assign(name, value)
        if noeval == 0 then os.setenv(name, tostring(value)) end
    end
    local function tdiv(a, b)
        local q = a // b
        if q < 0 and q * b ~= a then q = q + 1 end
        return q
    end
    local function apply(op, a, b)
        if op == "+" then return a + b
        elseif op == "-" then return a - b
        elseif op == "*" then return a * b
        elseif op == "/" or op == "%" then
            if b == 0 then
                if noeval > 0 then return 0 end
                expand_error("division by zero")
            end
            if op == "/" then return tdiv(a, b) end
            return a - tdiv(a, b) * b
        elseif op == "<<" then return a << b
        elseif op == ">>" then
            if a >= 0 then return a >> b end
            return ~((~a) >> b)
        elseif op == "&" then return a & b
        elseif op == "|" then return a | b
        elseif op == "^" then return a ~ b
        elseif op == "==" then return a == b and 1 or 0
        elseif op == "!=" then return a ~= b and 1 or 0
        elseif op == "<" then return a < b and 1 or 0
        elseif op == "<=" then return a <= b and 1 or 0
        elseif op == ">" then return a > b and 1 or 0
        elseif op == ">=" then return a >= b and 1 or 0
        end
        expand_error("arithmetic syntax error near `" .. op .. "'")
    end

    local expr_comma, expr_assign, ternary
    local function primary()
        local t = take()
        if t.k == "num" then return t.v end
        if t.k == "name" then
            if is("++") or is("--") then
                local op = take().v
                local old = var_value(t.v)
                assign(t.v, old + (op == "++" and 1 or -1))
                return old
            end
            return var_value(t.v)
        end
        if t.k == "op" and t.v == "(" then
            local v = expr_comma()
            if not is(")") then expand_error("missing `)' in arithmetic expression") end
            take()
            return v
        end
        expand_error("arithmetic syntax error: " .. expr)
    end
    local function unary()
        local t = peek()
        if t.k == "op" then
            if t.v == "+" then take(); return unary()
            elseif t.v == "-" then take(); return -unary()
            elseif t.v == "!" then take(); return unary() == 0 and 1 or 0
            elseif t.v == "~" then take(); return ~unary()
            elseif t.v == "++" or t.v == "--" then
                take()
                local nt = take()
                if nt.k ~= "name" then expand_error("`" .. t.v .. "' needs a variable") end
                local v = var_value(nt.v) + (t.v == "++" and 1 or -1)
                assign(nt.v, v)
                return v
            end
        end
        return primary()
    end
    local function power()
        local base = unary()
        if is("**") then
            take()
            local e = power()
            if e < 0 then expand_error("exponent less than 0") end
            local r = 1
            while e > 0 do
                if e % 2 == 1 then r = r * base end
                base = base * base
                e = e // 2
            end
            return r
        end
        return base
    end
    local function binary(level)
        if level > #ARITH_LEVELS then return power() end
        local ops = ARITH_LEVELS[level]
        local left = binary(level + 1)
        while true do
            local t, op = peek(), nil
            if t.k == "op" then
                for _, o in ipairs(ops) do
                    if t.v == o then op = o; break end
                end
            end
            if not op then return left end
            take()
            if op == "||" or op == "&&" then
                local decided = (op == "||") == (left ~= 0)
                if decided then noeval = noeval + 1 end
                local right = binary(level + 1)
                if decided then
                    noeval = noeval - 1
                    left = op == "||" and 1 or 0
                else
                    left = right ~= 0 and 1 or 0
                end
            else
                left = apply(op, left, binary(level + 1))
            end
        end
    end
    function ternary()
        local cond = binary(1)
        if not is("?") then return cond end
        take()
        if cond == 0 then noeval = noeval + 1 end
        local a = expr_assign()
        if cond == 0 then noeval = noeval - 1 end
        if not is(":") then expand_error("expected `:' in arithmetic expression") end
        take()
        if cond ~= 0 then noeval = noeval + 1 end
        local b = ternary()
        if cond ~= 0 then noeval = noeval - 1 end
        return cond ~= 0 and a or b
    end
    function expr_assign()
        local t, n = toks[pos], toks[pos + 1]
        if t.k == "name" and n and n.k == "op" and ARITH_ASSIGN[n.v] then
            take()
            take()
            local value = expr_assign()
            if n.v ~= "=" then value = apply(n.v:sub(1, -2), var_value(t.v), value) end
            assign(t.v, value)
            return value
        end
        return ternary()
    end
    function expr_comma()
        local v = expr_assign()
        while is(",") do
            take()
            v = expr_assign()
        end
        return v
    end

    if toks[1].k == "end" then return 0 end
    local v = expr_comma()
    if toks[pos].k ~= "end" then expand_error("arithmetic syntax error: " .. expr) end
    return v
end

------------------------------------------------------------------------
-- Word expansion
------------------------------------------------------------------------

local function param_expand(p)
    local name = p.name
    if p.len then
        if name == "@" or name == "*" then return tostring(#scriptArgs) end
        local v = param_value(name) or ""
        return tostring(utf8.len(v) or #v)
    end
    local v = param_value(name)
    local op = p.op
    if not op then
        if v == nil and opts.nounset and name ~= "@" and name ~= "*" then
            expand_error(name .. ": parameter not set", true)
        end
        return v or ""
    end
    local colon = op:sub(1, 1) == ":"
    local base = colon and op:sub(2) or op
    local missing = v == nil or (colon and v == "")
    if base == "-" then
        if missing then return expand_string(p.arg) end
        return v
    elseif base == "=" then
        if missing then
            if not valid_name(name) then expand_error("$" .. name .. ": cannot assign in this way") end
            local value = expand_string(p.arg)
            os.setenv(name, value)
            return value
        end
        return v
    elseif base == "?" then
        if missing then
            local message = expand_string(p.arg)
            if message == "" then message = v == nil and "parameter not set" or "parameter null or not set" end
            expand_error(name .. ": " .. message, true)
        end
        return v
    elseif base == "+" then
        if missing then return "" end
        return expand_string(p.arg)
    end
    -- # ## % %%: remove the shortest / longest matching prefix / suffix
    v = v or ""
    local tokens = compile_glob(expand_string_mask(p.arg))
    local bounds, i = { 1 }, 1
    while i <= #v do
        i = i + char_width(v, i)
        bounds[#bounds + 1] = i
    end
    if op == "#" then
        for k = 1, #bounds do
            if glob_matches(v:sub(1, bounds[k] - 1), tokens) then return v:sub(bounds[k]) end
        end
    elseif op == "##" then
        for k = #bounds, 1, -1 do
            if glob_matches(v:sub(1, bounds[k] - 1), tokens) then return v:sub(bounds[k]) end
        end
    elseif op == "%" then
        for k = #bounds, 1, -1 do
            if glob_matches(v:sub(bounds[k]), tokens) then return v:sub(1, bounds[k] - 1) end
        end
    else
        for k = 1, #bounds do
            if glob_matches(v:sub(bounds[k]), tokens) then return v:sub(1, bounds[k] - 1) end
        end
    end
    return v
end

-- Expands a word into fields { value, mask }, the mask marking the bytes
-- that may act as wildcards. Unquoted expansion results are split on IFS
-- unless nosplit is set.
function expand_fields(word, nosplit)
    local fields = {}
    local buf, mask, started = {}, {}, false
    local ifs = nosplit and "" or ifs_value()
    local function emit(force)
        if started or force then fields[#fields + 1] = { value = table.concat(buf), mask = mask } end
        buf, mask, started = {}, {}, false
    end
    local function push(text, globbable)
        buf[#buf + 1] = text
        for _ = 1, #text do mask[#mask + 1] = globbable end
        started = true
    end
    local function push_split(text)
        if ifs == "" then
            if text ~= "" then push(text, true) end
            return
        end
        local i, n = 1, #text
        while i <= n do
            local c = text:sub(i, i)
            if ifs:find(c, 1, true) then
                if c == " " or c == "\t" or c == "\n" then
                    if started then emit() end
                else
                    emit(true)
                end
                i = i + 1
            else
                local j = i
                while j <= n and not ifs:find(text:sub(j, j), 1, true) do j = j + 1 end
                push(text:sub(i, j - 1), true)
                i = j
            end
        end
    end
    for _, p in ipairs(word.parts) do
        local t = p.t
        if t == "lit" then
            push(p.s, not p.q)
        elseif t == "tilde" then
            push(home_path() or "~", false)
        elseif t == "param" and not p.op and not p.len and (p.name == "@" or (p.name == "*" and not p.q)) then
            for k, a in ipairs(scriptArgs) do
                if p.q then
                    if k > 1 then emit(true) end
                    push(a, false)
                else
                    if k > 1 then emit() end
                    push_split(a)
                end
            end
        else
            local v
            if t == "param" then
                v = param_expand(p)
            elseif t == "cmd" then
                v = command_substitution(p.src)
            else
                v = tostring(arith_eval(expand_string(p.expr)))
            end
            if p.q then push(v, false) else push_split(v) end
        end
    end
    emit()
    return fields
end

-- A word as one string, without field splitting or pathname expansion
-- (assignments, case words and patterns, ${...} operands).
function expand_string_mask(word)
    local fields = expand_fields(word, true)
    if #fields == 1 then return fields[1].value, fields[1].mask end
    local values, mask = {}, {}
    for i, f in ipairs(fields) do
        if i > 1 then
            values[#values + 1] = " "
            mask[#mask + 1] = false
        end
        values[#values + 1] = f.value
        for _, m in ipairs(f.mask) do mask[#mask + 1] = m end
    end
    return table.concat(values), mask
end

function expand_string(word)
    return (expand_string_mask(word))
end

local function expand_argv(words)
    local argv = {}
    for _, w in ipairs(words) do
        for _, f in ipairs(expand_fields(w)) do
            for _, m in ipairs(pathname_expand(f)) do argv[#argv + 1] = m end
        end
    end
    return argv
end

local DECLARATIONS = { export = true, ["local"] = true, readonly = true }

local function expand_redirs(redirs)
    local result = {}
    for _, r in ipairs(redirs) do
        local e = { op = r.op }
        if r.op == "<" or r.op == "<<" or r.op == "<<-" or r.op == "<&" then e.fd = r.fd or 0
        else e.fd = r.fd or 1 end
        if r.heredoc then
            local hd = r.heredoc
            if hd.quoted then
                e.body = hd.body
            else
                hd.parts = hd.parts or (scan_parts(hd.body, 1, "dq", true, r.line))
                e.body = expand_string({ parts = hd.parts })
            end
        elseif r.op == ">&" or r.op == "<&" then
            local target = expand_string(r.target)
            if target:match("^%d+$") then
                e.dup = tonumber(target)
            elseif r.op == ">&" and not r.fd and target ~= "-" then
                e.op, e.fd, e.path = "&>", 1, target
            else
                expand_error(target .. ": bad file descriptor")
            end
        else
            local matches = {}
            for _, f in ipairs(expand_fields(r.target)) do
                for _, m in ipairs(pathname_expand(f)) do matches[#matches + 1] = m end
            end
            if #matches ~= 1 then
                expand_error(expand_string(r.target) .. ": ambiguous redirect")
            end
            e.path = matches[1]
        end
        result[#result + 1] = e
    end
    return result
end

local function expand_command(node)
    last_cmdsub_status = nil
    local argv, decl = {}, false
    for i, w in ipairs(node.words) do
        local name, value
        if decl then name, value = assignment_of(w) end
        if name then
            argv[#argv + 1] = name .. "=" .. expand_string(value)
        else
            for _, f in ipairs(expand_fields(w)) do
                for _, m in ipairs(pathname_expand(f)) do argv[#argv + 1] = m end
            end
        end
        if i == 1 and DECLARATIONS[argv[1] or ""] then decl = true end
    end
    local assigns = {}
    for _, a in ipairs(node.assigns) do assigns[#assigns + 1] = { a.name, expand_string(a.value) } end
    return argv, assigns, expand_redirs(node.redirs)
end

-- Reports an expansion error. A fatal one (${x?}, set -u) ends a script.
local function expansion_failed(err)
    if type(err) == "table" and (err.sh_expand or err.sh_syntax) then
        io.stderr:write("sh: " .. (err.sh_expand or err.sh_syntax) .. "\n")
        if err.fatal and not is_interactive then os.exit(1) end
        return 1
    end
    error(err, 0)
end

------------------------------------------------------------------------
-- Redirections
------------------------------------------------------------------------

local function close_redirects(handles)
    for i = #handles, 1, -1 do
        local h = handles[i]
        if type(h) == "number" then
            pcall(fs.close, h)
        elseif type(h) == "table" and h.remove then
            pcall(fs.remove, h.remove)
        else
            pcall(function() h:close() end)
        end
    end
end

local heredoc_counter = 0

-- Opens the files of expanded redirections. Returns a mapping
-- { [target fd] = open fd } and the handles to close afterwards.
local function open_redirects(redirects)
    local mapping, handles = {}, {}
    local function fail(message)
        close_redirects(handles)
        return nil, nil, message
    end
    for _, redirect in ipairs(redirects) do
        local fd
        if redirect.dup then
            local source = mapping[redirect.dup]
            if source then
                fd = source
            else
                local copy, err = fs.dup(redirect.dup, 3)
                if type(copy) ~= "number" or copy < 0 then
                    return fail(redirect.dup .. ": " .. tostring(err or "bad file descriptor"))
                end
                handles[#handles + 1] = copy
                fd = copy
            end
        elseif redirect.body then
            local body = redirect.body
            if #body <= HEREDOC_PIPE_LIMIT then
                local rfd, wfd = fs.pipe()
                if type(rfd) ~= "number" or type(wfd) ~= "number" then return fail("cannot create here-document") end
                fs.write(wfd, body)
                fs.close(wfd)
                handles[#handles + 1] = rfd
                fd = rfd
            else
                heredoc_counter = heredoc_counter + 1
                local pid = process.getCurrentPID and process.getCurrentPID() or 0
                local path = "/tmp/.sh-heredoc-" .. tostring(pid) .. "-" .. heredoc_counter
                local file, err = fs.open(path, "w")
                if not file then return fail(path .. ": " .. tostring(err)) end
                file:write(body)
                file:close()
                handles[#handles + 1] = { remove = path }
                redirect = { op = "<", fd = redirect.fd, path = path }
            end
        end
        if not fd then
            local op = redirect.op
            local mode = (op == "<" or op == "<<" or op == "<<-") and "r"
                or ((op == ">>" or op == "&>>") and "a" or "w")
            local open_ok, file, err = pcall(fs.open, redirect.path, mode)
            if not open_ok then return fail(redirect.path .. ": " .. tostring(file)) end
            if not file then return fail(redirect.path .. ": " .. tostring(err or "open failed")) end
            handles[#handles + 1] = file
            fd = file:fd()
            if type(fd) ~= "number" or fd < 0 then return fail(redirect.path .. ": invalid file descriptor") end
            if fd < 3 then
                local safe_fd, dup_err = fs.dup(fd, 3)
                pcall(function() file:close() end)
                handles[#handles] = nil
                if type(safe_fd) ~= "number" or safe_fd < 0 then
                    return fail(redirect.path .. ": " .. tostring(dup_err or "dup failed"))
                end
                fd = safe_fd
                handles[#handles + 1] = fd
            end
        end
        mapping[redirect.fd] = fd
        if redirect.op == "&>" or redirect.op == "&>>" then mapping[2] = fd end
    end
    return mapping, handles
end

-- Runs fn with the shell's own descriptors redirected, then restores them.
local function with_redirects(redirects, fn)
    if #redirects == 0 then return fn() end
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
    local ok, status, ctl = true, 1, nil
    if apply_err then
        io.stderr:write("sh: redirection: " .. tostring(apply_err) .. "\n")
    else
        ok, status, ctl = pcall(fn)
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
    if not ok then error(status, 0) end
    return status, ctl
end

local function with_node_redirects(node, fn)
    if not node.redirs or #node.redirs == 0 then return fn() end
    local ok, redirs = pcall(expand_redirs, node.redirs)
    if not ok then return expansion_failed(redirs) end
    return with_redirects(redirs, fn)
end

-- Runs fn with temporary variable assignments (FOO=bar command).
local function with_env(assigns, fn)
    if #assigns == 0 then return fn() end
    local saved = {}
    for i, a in ipairs(assigns) do
        saved[i] = os.getenv(a[1])
        os.setenv(a[1], a[2])
    end
    local ok, status, ctl = pcall(fn)
    for i = #assigns, 1, -1 do os.setenv(assigns[i][1], saved[i]) end
    if not ok then error(status, 0) end
    return status, ctl
end

------------------------------------------------------------------------
-- Execution
------------------------------------------------------------------------

-- Shell source for a child "sh -c": the current options and functions,
-- then the command itself.
local function child_script(src)
    local lines = {}
    local flags = ""
    if opts.errexit then flags = flags .. "e" end
    if opts.nounset then flags = flags .. "u" end
    if opts.xtrace then flags = flags .. "x" end
    if opts.noglob then flags = flags .. "f" end
    if flags ~= "" then lines[#lines + 1] = "set -" .. flags end
    for _, name in ipairs(function_order) do
        local f = functions[name]
        if f then lines[#lines + 1] = f.src end
    end
    lines[#lines + 1] = src
    return table.concat(lines, "\n")
end

local function child_shell_args(src)
    local args = { "-c", child_script(src), scriptName }
    for _, a in ipairs(scriptArgs) do args[#args + 1] = a end
    return args
end

local function call_builtin(name, args)
    local ok, status, ctl = pcall(builtins[name], args)
    if not ok then
        if type(status) == "table" then error(status, 0) end
        io.stderr:write(name .. ": " .. tostring(status) .. "\n")
        return 1
    end
    return status or 0, ctl
end

-- Starts a program with exec(2) semantics (all descriptors inherited) and
-- waits for it.
local function exec_external(path, argv)
    local exec_args = {}
    for i = 2, #argv do exec_args[#exec_args + 1] = argv[i] end
    local pid, err = process.exec(path, exec_args)
    if not pid or pid == -1 then
        io.stderr:write(argv[1] .. ": " .. (err or "exec failed") .. "\n")
        return 127
    end
    local wait_err, status = process.wait(pid)
    if wait_err then
        io.stderr:write(argv[1] .. ": process error: " .. tostring(wait_err) .. "\n")
        return 1
    end
    return type(status) == "number" and status or 0
end

local function wait_child(pid, instance, label)
    if instance == nil then
        local proc = process.get(pid)
        instance = proc and proc.instance
    end
    local wait_err, status = process.wait(pid, instance)
    if wait_err then
        io.stderr:write(label .. ": process error: " .. tostring(wait_err) .. "\n")
        return 1
    end
    return type(status) == "number" and status or 0
end

local function run_external(argv, redirs, assigns)
    local cmd = argv[1]
    local path = find_in_path(cmd)
    if not path then
        io.stderr:write(cmd .. ": command not found\n")
        return 127
    end
    if #redirs == 0 then
        return with_env(assigns, function() return exec_external(path, argv) end)
    end
    for _, r in ipairs(redirs) do
        if r.fd > 2 then
            -- spawn maps only the standard streams; redirect the shell itself
            return with_redirects(redirs, function()
                return with_env(assigns, function() return exec_external(path, argv) end)
            end)
        end
    end
    local mapping, handles, err = open_redirects(redirs)
    if not mapping then
        io.stderr:write("sh: " .. tostring(err) .. "\n")
        return 1
    end
    local child_args = {}
    for i = 2, #argv do child_args[#child_args + 1] = argv[i] end
    local pid, spawn_err, instance = with_env(assigns, function()
        return process.spawn(path, child_args, mapping)
    end)
    close_redirects(handles)
    if not pid or pid == -1 then
        io.stderr:write(cmd .. ": " .. tostring(spawn_err or "spawn failed") .. "\n")
        return 1
    end
    return wait_child(pid, instance, cmd)
end

local function call_function(name, argv, redirs)
    local f = functions[name]
    if #frames >= MAX_CALL_DEPTH then
        io.stderr:write(name .. ": maximum function nesting level exceeded\n")
        return 1
    end
    local saved_args = scriptArgs
    scriptArgs = { table.unpack(argv, 2) }
    local frame = { locals = {}, order = {} }
    frames[#frames + 1] = frame
    local ok, status, ctl = pcall(with_redirects, redirs, function() return exec_node(f.body) end)
    frames[#frames] = nil
    for i = #frame.order, 1, -1 do
        local var = frame.order[i]
        local old = frame.locals[var]
        if old == false then old = nil end
        os.setenv(var, old)
    end
    scriptArgs = saved_args
    if not ok then error(status, 0) end
    if ctl and ctl.k == "return" then return ctl.status end
    return status
end

-- exec: with a command, run it and leave the shell with its status;
-- without one, apply the redirections to the shell itself.
local function builtin_exec(argv, assigns, redirs)
    if #argv == 1 then
        for _, a in ipairs(assigns) do os.setenv(a[1], a[2]) end
        if #redirs == 0 then return 0 end
        local mapping, handles, err = open_redirects(redirs)
        if not mapping then
            io.stderr:write("exec: " .. tostring(err) .. "\n")
            return 1
        end
        local kept = {}
        for fd, source in pairs(mapping) do
            if source ~= fd then fs.dup2(source, fd) end
            kept[fd] = true
        end
        -- a file opened straight onto its target descriptor stays open
        local closing = {}
        for _, h in ipairs(handles) do
            local fd = type(h) == "number" and h or (type(h) == "table" and h.fd and h:fd())
            if not (fd and kept[fd]) then closing[#closing + 1] = h end
        end
        close_redirects(closing)
        return 0
    end
    local status = run_argv({ table.unpack(argv, 2) }, assigns, redirs, false)
    os.exit(status)
    return status
end

function run_argv(argv, assigns, redirs, no_functions)
    local name = argv[1]
    if name == "exec" then return builtin_exec(argv, assigns, redirs) end
    if name == "command" and argv[2] and argv[2] ~= "-v" and argv[2] ~= "-V" then
        return run_argv({ table.unpack(argv, 2) }, assigns, redirs, true)
    end
    if not no_functions and functions[name] then
        return with_env(assigns, function() return call_function(name, argv, redirs) end)
    end
    if builtins[name] then
        return with_redirects(redirs, function()
            return with_env(assigns, function() return call_builtin(name, argv) end)
        end)
    end
    return run_external(argv, redirs, assigns)
end

local function exec_simple(node)
    local ok, argv, assigns, redirs = pcall(expand_command, node)
    if not ok then return expansion_failed(argv) end
    if #argv == 0 then
        for _, a in ipairs(assigns) do os.setenv(a[1], a[2]) end
        if #redirs > 0 then
            local mapping, handles, err = open_redirects(redirs)
            if not mapping then
                io.stderr:write("sh: " .. tostring(err) .. "\n")
                return 1
            end
            close_redirects(handles)
        end
        return last_cmdsub_status or 0
    end
    if opts.xtrace then
        io.stderr:write((os.getenv("PS4") or "+ ") .. table.concat(argv, " ") .. "\n")
    end
    return run_argv(argv, assigns, redirs, false)
end

-- How one pipeline stage is started: a builtin in a "sh --builtin" child,
-- a program directly, anything else in a child shell.
local function pipeline_stage(node)
    if node.type == "simple" then
        local plain = true
        for _, r in ipairs(node.redirs) do
            if r.fd and r.fd > 2 then plain = false end
        end
        local ok, argv, assigns, redirs = pcall(expand_command, node)
        if not ok then return nil, expansion_failed(argv) end
        local name = argv[1]
        if plain and name and not functions[name] and name ~= "exec" and name ~= "command" then
            if builtins[name] then
                local args = { "--builtin", name }
                for j = 2, #argv do args[#args + 1] = argv[j] end
                return { path = SHELL_PATH, args = args, label = name, redirects = redirs, assigns = assigns }
            end
            local path = find_in_path(name)
            if not path then
                io.stderr:write(name .. ": command not found\n")
                return nil, 127
            end
            local args = {}
            for j = 2, #argv do args[#args + 1] = argv[j] end
            return { path = path, args = args, label = name, redirects = redirs, assigns = assigns }
        end
    end
    return { path = SHELL_PATH, args = child_shell_args(node_src(node)), label = "sh", redirects = {}, assigns = {} }
end

local function run_pipeline(cmds)
    local stages = {}
    for i, node in ipairs(cmds) do
        local stage, status = pipeline_stage(node)
        if not stage then return status end
        stages[i] = stage
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
        local pid, err, instance = with_env(stage.assigns, function()
            return process.spawn(stage.path, stage.args, stdio)
        end)
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

local function run_background(node)
    local stage, status = pipeline_stage(node)
    if not stage then return status end
    local mapping, handles, err = open_redirects(stage.redirects)
    if not mapping then
        io.stderr:write("sh: " .. tostring(err) .. "\n")
        return 1
    end
    local pid, spawn_err, instance = with_env(stage.assigns, function()
        return process.spawn(stage.path, stage.args, mapping)
    end)
    close_redirects(handles)
    if not pid or pid == -1 then
        io.stderr:write(stage.label .. ": " .. tostring(spawn_err or "spawn failed") .. "\n")
        return 1
    end
    if instance == nil then
        local proc = process.get(pid)
        instance = proc and proc.instance
    end
    background[pid] = instance or true
    last_bg_pid = pid
    if is_interactive then io.stderr:write("[" .. pid .. "]\n") end
    return 0
end

local function spawn_capture(path, args)
    local rfd, wfd = fs.pipe()
    if type(rfd) ~= "number" or type(wfd) ~= "number" then
        io.stderr:write("sh: pipe: failed to create pipe\n")
        return 1, ""
    end
    local pid, err, instance = process.spawn(path, args, { [1] = wfd })
    fs.close(wfd)
    if not pid or pid == -1 then
        fs.close(rfd)
        io.stderr:write("sh: " .. tostring(err or "spawn failed") .. "\n")
        return 127, ""
    end
    local data = fs.read(rfd, "*a")
    fs.close(rfd)
    return wait_child(pid, instance, "sh"), data or ""
end

-- Builtins that only produce output may run inside $(...) without a child
-- shell; anything that changes the shell's state must not.
local CAPTURE_SAFE = { echo = true, printf = true, pwd = true, test = true, ["["] = true,
    ["true"] = true, ["false"] = true, [":"] = true, type = true }

local function run_capture(src)
    local ok, node = pcall(function()
        local parser = new_parser(new_lexer(src))
        local first = parser:complete_command()
        if parser:complete_command() ~= nil then return nil end
        return first
    end)
    local cmd = ok and node and #node.items == 1 and not node.items[1].bg and node.items[1].node
    if cmd and cmd.type == "simple" and #cmd.assigns == 0 and #cmd.redirs == 0 and #cmd.words > 0 then
        local argv = expand_argv(cmd.words)
        local name = argv[1]
        if name and not functions[name] then
            if CAPTURE_SAFE[name] and builtins[name] then
                local saved = capture
                capture = {}
                local cok, status = pcall(call_builtin, name, argv)
                local text = table.concat(capture)
                capture = saved
                if not cok then error(status, 0) end
                return status, text
            elseif not builtins[name] and name ~= "exec" then
                local path = find_in_path(name)
                if not path then
                    io.stderr:write(name .. ": command not found\n")
                    return 127, ""
                end
                return spawn_capture(path, { table.unpack(argv, 2) })
            end
        end
    end
    return spawn_capture(SHELL_PATH, child_shell_args(src))
end

function command_substitution(src)
    local status, output = run_capture(src)
    last_cmdsub_status = status
    return (output:gsub("\n+$", ""))
end

local yield_count = 0
local function loop_tick()
    -- give other processes a turn during long loops
    yield_count = yield_count + 1
    if yield_count >= 32 then
        yield_count = 0
        coroutine.yield()
    end
end

-- What a loop does with a break/continue/return coming out of its body:
-- "stop", "next", or the control item to pass further out.
local function loop_control(ctl)
    if ctl.k == "break" then
        if ctl.n > 1 then return { k = "break", n = ctl.n - 1 } end
        return "stop"
    elseif ctl.k == "continue" then
        if ctl.n > 1 then return { k = "continue", n = ctl.n - 1 } end
        return "next"
    end
    return ctl
end

local function exec_loop(node)
    local status, result_ctl = 0, nil
    loop_depth = loop_depth + 1
    while true do
        loop_tick()
        cond_depth = cond_depth + 1
        local cond_status, ctl = exec_node(node.cond)
        cond_depth = cond_depth - 1
        local action
        if ctl then
            action = loop_control(ctl)
        elseif (cond_status == 0) ~= (node.type == "while") then
            break
        else
            local body_status
            body_status, ctl = exec_node(node.body)
            status = body_status or 0
            if ctl then action = loop_control(ctl) end
        end
        if action == "stop" then break end
        if type(action) == "table" then
            result_ctl = action
            break
        end
    end
    loop_depth = loop_depth - 1
    return status, result_ctl
end

local function exec_for(node)
    local values
    if node.words then
        local ok, result = pcall(expand_argv, node.words)
        if not ok then return expansion_failed(result) end
        values = result
    else
        values = { table.unpack(scriptArgs) }
    end
    local status, result_ctl = 0, nil
    loop_depth = loop_depth + 1
    for _, v in ipairs(values) do
        loop_tick()
        os.setenv(node.var, v)
        local body_status, ctl = exec_node(node.body)
        status = body_status or 0
        if ctl then
            local action = loop_control(ctl)
            if action == "stop" then break end
            if type(action) == "table" then
                result_ctl = action
                break
            end
        end
    end
    loop_depth = loop_depth - 1
    return status, result_ctl
end

local function exec_case(node)
    local ok, item = pcall(function()
        local subject = expand_string(node.word)
        for _, candidate in ipairs(node.items) do
            for _, pattern in ipairs(candidate.patterns) do
                if glob_matches(subject, (compile_glob(expand_string_mask(pattern)))) then
                    return candidate
                end
            end
        end
    end)
    if not ok then return expansion_failed(item) end
    if item then return exec_node(item.body) end
    return 0
end

local function exec_compound(node)
    local t = node.type
    if t == "brace" then
        return exec_node(node.body)
    elseif t == "subshell" then
        local args = child_shell_args(node_src(node, node.inner_s, node.inner_e))
        return exec_external(SHELL_PATH, { "sh", table.unpack(args) })
    elseif t == "if" then
        for _, clause in ipairs(node.clauses) do
            cond_depth = cond_depth + 1
            local status, ctl = exec_node(clause.cond)
            cond_depth = cond_depth - 1
            if ctl then return status, ctl end
            if status == 0 then return exec_node(clause.body) end
        end
        if node.else_body then return exec_node(node.else_body) end
        return 0
    elseif t == "while" or t == "until" then
        return exec_loop(node)
    elseif t == "for" then
        return exec_for(node)
    elseif t == "case" then
        return exec_case(node)
    end
    error("unknown node type " .. tostring(t))
end

local function exec_list(list)
    local status, ctl = 0, nil
    for _, item in ipairs(list.items) do
        errexit_exempt = false
        if item.bg then
            status = run_background(item.node)
        else
            status, ctl = exec_node(item.node)
            status = status or 0
        end
        set_status(status)
        if ctl then return status, ctl end
        if opts.errexit and status ~= 0 and cond_depth == 0 and not errexit_exempt and not item.bg then
            os.exit(status)
        end
    end
    return status
end

local function exec_andor(node)
    cond_depth = cond_depth + 1
    local status, ctl = exec_node(node.first)
    cond_depth = cond_depth - 1
    if ctl then return status, ctl end
    local ran_last = false
    for i, r in ipairs(node.rest) do
        set_status(status)
        if (r.op == "&&") == (status == 0) then
            local last = i == #node.rest
            if not last then cond_depth = cond_depth + 1 end
            status, ctl = exec_node(r.node)
            if not last then cond_depth = cond_depth - 1 end
            if ctl then return status, ctl end
            ran_last = last
        end
    end
    errexit_exempt = not ran_last
    return status
end

local function exec_pipeline(node)
    local status
    if #node.cmds == 1 then
        cond_depth = cond_depth + 1
        local ctl
        status, ctl = exec_node(node.cmds[1])
        cond_depth = cond_depth - 1
        if ctl then return status, ctl end
    else
        status = run_pipeline(node.cmds)
    end
    if node.bang then
        errexit_exempt = true
        status = status == 0 and 1 or 0
    end
    return status
end

function exec_node(node)
    local t = node.type
    if t == "simple" then return exec_simple(node)
    elseif t == "list" then return exec_list(node)
    elseif t == "andor" then return exec_andor(node)
    elseif t == "pipeline" then return exec_pipeline(node)
    elseif t == "funcdef" then
        if not functions[node.name] then function_order[#function_order + 1] = node.name end
        functions[node.name] = { body = node.body, src = node_src(node) }
        return 0
    end
    return with_node_redirects(node, function() return exec_compound(node) end)
end

------------------------------------------------------------------------
-- Builtins
------------------------------------------------------------------------

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

local function read_file(path)
    local opened, file, err = pcall(fs.open, path, "r")
    if not opened then return nil, file end
    if not file then return nil, err end
    local data = file:read("*a")
    file:close()
    return data or ""
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
        out(string.format("%5d  %s\n", i, entries[i]))
    end
    return 0
end

builtins["cd"] = function(args)
    local target = args[2] or home_path() or "/"
    local print_dir = false
    if target == "-" then
        target = os.getenv("OLDPWD")
        if not target or target == "" then
            io.stderr:write("cd: OLDPWD not set\n")
            return 1
        end
        print_dir = true
    end
    local old = process.cwd()
    local cwd, err = process.cwd(target)
    if not cwd then
        io.stderr:write("cd: " .. target .. ": " .. (err or "Cannot change directory") .. "\n")
        return 1
    end
    if old then os.setenv("OLDPWD", old) end
    os.setenv("PWD", cwd)
    if print_dir then out(cwd .. "\n") end
    return 0
end

builtins["pwd"] = function()
    out(tostring(process.cwd()) .. "\n")
    return 0
end

builtins["echo"] = function(args)
    local i, newline = 2, true
    while args[i] == "-n" do
        newline = false
        i = i + 1
    end
    out(table.concat(args, " ", i) .. (newline and "\n" or ""))
    return 0
end

builtins["exit"] = function(args)
    local code = args[2] and tonumber(args[2]) or last_status
    os.exit(code)
    return code
end

local function print_variables(prefix)
    local environ = process.getEnviron and process.getEnviron()
    if type(environ) ~= "table" then return end
    local keys = {}
    for k in pairs(environ) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out(prefix .. k .. "=" .. tostring(environ[k]) .. "\n") end
end

builtins["export"] = function(args)
    if #args == 1 or args[2] == "-p" then
        print_variables("export ")
        return 0
    end
    local status = 0
    for i = 2, #args do
        local k, v = args[i]:match("^([%w_]+)=(.*)$")
        if k then
            os.setenv(k, v)
        elseif not valid_name(args[i]) then
            io.stderr:write("export: `" .. args[i] .. "': not a valid identifier\n")
            status = 1
        end
    end
    return status
end

builtins["unset"] = function(args)
    local mode, i = "v", 2
    if args[2] == "-f" or args[2] == "-v" then
        mode = args[2]:sub(2)
        i = 3
    end
    for j = i, #args do
        if mode == "f" then
            functions[args[j]] = nil
        else
            os.setenv(args[j], nil)
        end
    end
    return 0
end

builtins["env"] = function()
    print_variables("")
    return 0
end

builtins["local"] = function(args)
    local frame = frames[#frames]
    if not frame then
        io.stderr:write("local: can only be used in a function\n")
        return 1
    end
    local status = 0
    for i = 2, #args do
        local name, value = args[i]:match("^([%a_][%w_]*)=(.*)$")
        name = name or args[i]
        if not valid_name(name) then
            io.stderr:write("local: `" .. args[i] .. "': not a valid identifier\n")
            status = 1
        else
            if frame.locals[name] == nil then
                frame.locals[name] = os.getenv(name) or false
                frame.order[#frame.order + 1] = name
            end
            os.setenv(name, value)
        end
    end
    return status
end

builtins["true"] = function() return 0 end
builtins["false"] = function() return 1 end
builtins[":"] = function() return 0 end

builtins["return"] = function(args)
    local n = last_status
    if args[2] then
        n = tonumber(args[2])
        if not n then
            io.stderr:write("return: " .. args[2] .. ": numeric argument required\n")
            n = 2
        end
    end
    if #frames == 0 and source_depth == 0 then
        io.stderr:write("return: can only `return' from a function or sourced script\n")
        return 1
    end
    return n, { k = "return", status = n }
end

local function loop_builtin(kind)
    return function(args)
        local n = tonumber(args[2] or "1")
        if not n or n < 1 then
            io.stderr:write(kind .. ": " .. tostring(args[2]) .. ": loop count out of range\n")
            return 1
        end
        if loop_depth == 0 then return 0 end
        return 0, { k = kind, n = math.min(n, loop_depth) }
    end
end
builtins["break"] = loop_builtin("break")
builtins["continue"] = loop_builtin("continue")

builtins["shift"] = function(args)
    local n = tonumber(args[2] or "1")
    if not n or n < 0 or n > #scriptArgs then
        io.stderr:write("shift: shift count out of range\n")
        return 1
    end
    scriptArgs = { table.unpack(scriptArgs, n + 1) }
    return 0
end

local OPTION_LETTERS = { e = "errexit", u = "nounset", x = "xtrace", f = "noglob" }

builtins["set"] = function(args)
    if #args == 1 then
        print_variables("")
        return 0
    end
    local i = 2
    while i <= #args do
        local a = args[i]
        if a == "--" then
            scriptArgs = { table.unpack(args, i + 1) }
            return 0
        elseif a == "-o" or a == "+o" then
            local name = args[i + 1]
            if not name then
                for _, option in pairs(OPTION_LETTERS) do
                    out(string.format("%-12s%s\n", option, opts[option] and "on" or "off"))
                end
                return 0
            end
            if opts[name] == nil then
                io.stderr:write("set: " .. name .. ": invalid option name\n")
                return 1
            end
            opts[name] = a == "-o"
            i = i + 2
        elseif a:match("^[-+]%a+$") then
            for c in a:sub(2):gmatch(".") do
                local option = OPTION_LETTERS[c]
                if not option then
                    io.stderr:write("set: -" .. c .. ": invalid option\n")
                    return 2
                end
                opts[option] = a:sub(1, 1) == "-"
            end
            i = i + 1
        else
            scriptArgs = { table.unpack(args, i) }
            return 0
        end
    end
    return 0
end

builtins["eval"] = function(args)
    local text = table.concat(args, " ", 2)
    if text == "" then return 0 end
    return run_text(text, "eval")
end

local function source_file(args)
    local name = args[2]
    if not name then
        io.stderr:write(args[1] .. ": filename argument required\n")
        return 2
    end
    local path = name
    if not name:find("/", 1, true) then
        path = nil
        for dir in (os.getenv("PATH") or "/usr/ubin:/usr/bin:/bin"):gmatch("[^:]+") do
            local full = dir .. "/" .. name
            if fs.exists(full) and not fs.isDirectory(full) then
                path = full
                break
            end
        end
        path = path or name
    end
    local text, err = read_file(path)
    if not text then
        io.stderr:write(args[1] .. ": " .. name .. ": " .. tostring(err or "No such file") .. "\n")
        return 1
    end
    local saved
    if #args > 2 then
        saved = scriptArgs
        scriptArgs = { table.unpack(args, 3) }
    end
    source_depth = source_depth + 1
    local ok, status, ctl = pcall(run_text, text, name)
    source_depth = source_depth - 1
    if saved then scriptArgs = saved end
    if not ok then error(status, 0) end
    if ctl and ctl.k == "return" then return ctl.status end
    return status, ctl
end
builtins["."] = source_file
builtins["source"] = source_file

-- Listed for type/command/completion; run_argv handles exec itself.
builtins["exec"] = function() return 0 end

local function describe_command(name)
    if functions[name] then return "function", name end
    if builtins[name] then return "builtin", name end
    if RESERVED[name] then return "keyword", name end
    local path = find_in_path(name)
    if path then return "file", path end
end

builtins["command"] = function(args)
    local mode = args[2]
    if mode ~= "-v" and mode ~= "-V" then return 0 end
    local status = 0
    for i = 3, #args do
        local kind, detail = describe_command(args[i])
        if not kind then
            status = 1
            if mode == "-V" then io.stderr:write("command: " .. args[i] .. ": not found\n") end
        elseif mode == "-v" then
            out(detail .. "\n")
        else
            out(args[i] .. " is " .. (kind == "file" and detail or ("a shell " .. kind)) .. "\n")
        end
    end
    return status
end

builtins["type"] = function(args)
    local status = 0
    for i = 2, #args do
        local kind, detail = describe_command(args[i])
        if kind == "function" then out(args[i] .. " is a function\n")
        elseif kind == "builtin" then out(args[i] .. " is a shell builtin\n")
        elseif kind == "keyword" then out(args[i] .. " is a shell keyword\n")
        elseif kind == "file" then out(args[i] .. " is " .. detail .. "\n")
        else
            io.stderr:write("type: " .. args[i] .. ": not found\n")
            status = 1
        end
    end
    return status
end

builtins["read"] = function(args)
    local raw, prompt = false, nil
    local i = 2
    while i <= #args do
        local a = args[i]
        if a == "-r" then
            raw = true
            i = i + 1
        elseif a == "-p" then
            prompt = args[i + 1] or ""
            i = i + 2
        elseif a == "--" then
            i = i + 1
            break
        elseif a:sub(1, 1) == "-" and #a > 1 then
            io.stderr:write("read: " .. a .. ": invalid option\n")
            return 2
        else
            break
        end
    end
    local names = { table.unpack(args, i) }
    if #names == 0 then names[1] = "REPLY" end
    for _, n in ipairs(names) do
        if not valid_name(n) then
            io.stderr:write("read: `" .. n .. "': not a valid identifier\n")
            return 1
        end
    end
    if prompt then io.stderr:write(prompt) end

    local chars = {} -- { char, escaped }
    local function absorb(text)
        local k = 1
        while k <= #text do
            local c = text:sub(k, k)
            if not raw and c == "\\" then
                if k == #text then return true end -- line continuation
                chars[#chars + 1] = { text:sub(k + 1, k + 1), true }
                k = k + 2
            else
                chars[#chars + 1] = { c, false }
                k = k + 1
            end
        end
        return false
    end
    local line = io.read("*l")
    if line == nil then
        for _, n in ipairs(names) do os.setenv(n, "") end
        return 1
    end
    while absorb(line) do
        line = io.read("*l")
        if line == nil then break end
    end

    local ifs = ifs_value()
    local function is_ifs(ch) return ch and not ch[2] and ifs:find(ch[1], 1, true) ~= nil end
    local function is_ws(ch) return is_ifs(ch) and (ch[1] == " " or ch[1] == "\t" or ch[1] == "\n") end
    local pos = 1
    while is_ws(chars[pos]) do pos = pos + 1 end
    for index, name in ipairs(names) do
        local buf = {}
        if index == #names then
            local last = #chars
            while last >= pos and is_ws(chars[last]) do last = last - 1 end
            for k = pos, last do buf[#buf + 1] = chars[k][1] end
        else
            while chars[pos] and not is_ifs(chars[pos]) do
                buf[#buf + 1] = chars[pos][1]
                pos = pos + 1
            end
            while is_ws(chars[pos]) do pos = pos + 1 end
            if is_ifs(chars[pos]) then pos = pos + 1 end
            while is_ws(chars[pos]) do pos = pos + 1 end
        end
        os.setenv(name, table.concat(buf))
    end
    return 0
end

local ESCAPES = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", e = "\27",
    ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

-- Backslash escapes of printf formats and %b operands. Returns the text and
-- whether a \c asked for output to stop.
local function unescape(s, b_mode)
    local result, i = {}, 1
    while i <= #s do
        local c = s:sub(i, i)
        local n = s:sub(i + 1, i + 1)
        if c ~= "\\" or n == "" then
            result[#result + 1] = c
            i = i + 1
        elseif ESCAPES[n] then
            result[#result + 1] = ESCAPES[n]
            i = i + 2
        elseif n == "c" and b_mode then
            return table.concat(result), true
        elseif n == "x" then
            local hex = s:match("^%x%x?", i + 2)
            if hex then
                result[#result + 1] = string.char(tonumber(hex, 16))
                i = i + 2 + #hex
            else
                result[#result + 1] = "\\x"
                i = i + 2
            end
        elseif n:match("[0-7]") then
            local digits
            if b_mode and n == "0" then
                digits = s:match("^[0-7]?[0-7]?[0-7]?", i + 2)
                i = i + 2 + #digits
            else
                digits = s:match("^[0-7][0-7]?[0-7]?", i + 1)
                i = i + 1 + #digits
            end
            result[#result + 1] = string.char(tonumber(digits ~= "" and digits or "0", 8) % 256)
        else
            result[#result + 1] = "\\" .. n
            i = i + 2
        end
    end
    return table.concat(result), false
end

builtins["printf"] = function(args)
    local format = args[2]
    if not format then
        io.stderr:write("printf: usage: printf format [arguments]\n")
        return 2
    end
    local argi, status, stop = 3, 0, false
    local function next_arg()
        local a = args[argi]
        argi = argi + 1
        return a
    end
    local function number_arg()
        local a = next_arg()
        if a == nil or a == "" then return 0 end
        if a:match("^['\"]") then
            local ok, code = pcall(utf8.codepoint, a, 2)
            return ok and code or (a:byte(2) or 0)
        end
        local n = tonumber(a)
        if not n and a:match("^[+-]?0%d+$") then n = tonumber(a, 8) end
        if not n then
            io.stderr:write("printf: " .. a .. ": invalid number\n")
            status = 1
            return 0
        end
        return n
    end
    local function integer(n)
        return math.tointeger(n) or (n >= 0 and math.floor(n) or math.ceil(n))
    end
    repeat
        local start_argi = argi
        local result, i = {}, 1
        while i <= #format and not stop do
            local c = format:sub(i, i)
            if c == "%" then
                local flags, width, precision, conv = format:match("^%%([-+ #0]*)(%d*)(%.?%d*)(.?)", i)
                local spec = "%" .. flags .. width .. precision
                i = i + 1 + #flags + #width + #precision + #conv
                if conv == "%" then
                    result[#result + 1] = "%"
                elseif conv == "s" then
                    result[#result + 1] = string.format(spec .. "s", next_arg() or "")
                elseif conv == "b" then
                    local text, halt = unescape(next_arg() or "", true)
                    result[#result + 1] = string.format(spec .. "s", text)
                    if halt then stop = true end
                elseif conv == "c" then
                    local a = next_arg() or ""
                    result[#result + 1] = string.format(spec .. "s", a:match(utf8.charpattern) or "")
                elseif conv == "d" or conv == "i" then
                    result[#result + 1] = string.format(spec .. "d", integer(number_arg()))
                elseif conv == "o" or conv == "u" or conv == "x" or conv == "X" then
                    result[#result + 1] = string.format(spec .. conv, integer(number_arg()))
                elseif conv ~= "" and ("eEfgG"):find(conv, 1, true) then
                    result[#result + 1] = string.format(spec .. conv, number_arg() + 0.0)
                else
                    result[#result + 1] = spec .. conv
                end
            else
                local j = format:find("%", i, true) or (#format + 1)
                result[#result + 1] = (unescape(format:sub(i, j - 1), false))
                i = j
            end
        end
        out(table.concat(result))
    until stop or argi > #args or argi == start_argi
    return status
end

local function file_attributes(path)
    local ok, attr = pcall(fs.attributes, path)
    if ok then return attr end
end

local function followed(path)
    local ok, real = pcall(fs.realPath, path)
    if ok and real then return real end
    return path
end

local function file_type(path, follow)
    local attr = file_attributes(follow and followed(path) or path)
    return attr and attr.type
end

local TEST_UNARY = {
    ["-e"] = function(p) return fs.exists(p) end,
    ["-f"] = function(p) return file_type(p, true) == "VREG" end,
    ["-d"] = function(p) return fs.isDirectory(p) end,
    ["-L"] = function(p) return file_type(p, false) == "VLNK" end,
    ["-h"] = function(p) return file_type(p, false) == "VLNK" end,
    ["-c"] = function(p) return file_type(p, true) == "VCHR" end,
    ["-b"] = function(p) return file_type(p, true) == "VBLK" end,
    ["-r"] = function(p) return fs.exists(p) and fs.can(p, "r") end,
    ["-w"] = function(p) return fs.exists(p) and fs.can(p, "w") end,
    ["-x"] = function(p) return fs.exists(p) and fs.can(p, "x") end,
    ["-s"] = function(p)
        local attr = file_attributes(followed(p))
        return attr ~= nil and (attr.size or 0) > 0
    end,
    ["-n"] = function(s) return #s > 0 end,
    ["-z"] = function(s) return #s == 0 end,
    ["-t"] = function(fd) return io.isatty ~= nil and io.isatty(tonumber(fd) or -1) == true end,
}

local function test_integer(s)
    local n = math.tointeger(tonumber(s))
    if not n then error({ test_error = s .. ": integer expression expected" }, 0) end
    return n
end

local function mtime(p)
    local attr = file_attributes(followed(p))
    return attr and attr.mtime
end

local TEST_BINARY = {
    ["="] = function(a, b) return a == b end,
    ["=="] = function(a, b) return a == b end,
    ["!="] = function(a, b) return a ~= b end,
    ["<"] = function(a, b) return a < b end,
    [">"] = function(a, b) return a > b end,
    ["-eq"] = function(a, b) return test_integer(a) == test_integer(b) end,
    ["-ne"] = function(a, b) return test_integer(a) ~= test_integer(b) end,
    ["-lt"] = function(a, b) return test_integer(a) < test_integer(b) end,
    ["-le"] = function(a, b) return test_integer(a) <= test_integer(b) end,
    ["-gt"] = function(a, b) return test_integer(a) > test_integer(b) end,
    ["-ge"] = function(a, b) return test_integer(a) >= test_integer(b) end,
    ["-nt"] = function(a, b)
        local x, y = mtime(a), mtime(b)
        return x ~= nil and (y == nil or x > y)
    end,
    ["-ot"] = function(a, b)
        local x, y = mtime(a), mtime(b)
        return y ~= nil and (x == nil or x < y)
    end,
}

local function test_eval(argv)
    local n = #argv
    if n == 0 then return false end
    if n == 1 then return argv[1] ~= "" end
    if n == 2 then
        if argv[1] == "!" then return argv[2] == "" end
        if TEST_UNARY[argv[1]] then return TEST_UNARY[argv[1]](argv[2]) and true or false end
        error({ test_error = argv[1] .. ": unary operator expected" }, 0)
    end
    if n == 3 then
        if TEST_BINARY[argv[2]] then return TEST_BINARY[argv[2]](argv[1], argv[3]) end
        if argv[1] == "!" then return not test_eval({ argv[2], argv[3] }) end
        if argv[1] == "(" and argv[3] == ")" then return argv[2] ~= "" end
    end
    if n == 4 and argv[1] == "!" then return not test_eval({ argv[2], argv[3], argv[4] }) end

    local pos = 1
    local expr_or
    local function primary()
        local a = argv[pos]
        if a == nil then error({ test_error = "argument expected" }, 0) end
        if a == "!" then
            pos = pos + 1
            return not primary()
        end
        if a == "(" then
            pos = pos + 1
            local v = expr_or()
            if argv[pos] ~= ")" then error({ test_error = "`)' expected" }, 0) end
            pos = pos + 1
            return v
        end
        local op = argv[pos + 1]
        if op and TEST_BINARY[op] and argv[pos + 2] ~= nil then
            pos = pos + 3
            return TEST_BINARY[op](a, argv[pos - 1])
        end
        if TEST_UNARY[a] and argv[pos + 1] ~= nil then
            pos = pos + 2
            return TEST_UNARY[a](argv[pos - 1]) and true or false
        end
        pos = pos + 1
        return a ~= ""
    end
    local function expr_and()
        local v = primary()
        while argv[pos] == "-a" do
            pos = pos + 1
            local r = primary()
            v = v and r
        end
        return v
    end
    function expr_or()
        local v = expr_and()
        while argv[pos] == "-o" do
            pos = pos + 1
            local r = expr_and()
            v = v or r
        end
        return v
    end
    local v = expr_or()
    if pos <= n then error({ test_error = argv[pos] .. ": unexpected argument" }, 0) end
    return v
end

local function run_test(argv, name)
    local ok, result = pcall(test_eval, argv)
    if not ok then
        if type(result) == "table" and result.test_error then
            io.stderr:write(name .. ": " .. result.test_error .. "\n")
            return 2
        end
        if type(result) == "table" then error(result, 0) end
        io.stderr:write(name .. ": " .. tostring(result) .. "\n")
        return 2
    end
    return result and 0 or 1
end

builtins["test"] = function(args)
    return run_test({ table.unpack(args, 2) }, "test")
end

builtins["["] = function(args)
    if args[#args] ~= "]" then
        io.stderr:write("[: missing `]'\n")
        return 2
    end
    return run_test({ table.unpack(args, 2, #args - 1) }, "[")
end

builtins["wait"] = function(args)
    local targets = {}
    if #args > 1 then
        for i = 2, #args do targets[#targets + 1] = tonumber(args[i]) or -1 end
    else
        for pid in pairs(background) do targets[#targets + 1] = pid end
        table.sort(targets)
    end
    local status = 0
    for _, pid in ipairs(targets) do
        local instance = background[pid]
        if instance == nil then
            status = 127
        else
            background[pid] = nil
            local err, child_status = process.wait(pid, instance ~= true and instance or nil)
            status = err and 127 or (type(child_status) == "number" and child_status or 0)
        end
    end
    return status
end

builtins["help"] = function()
    out(colors.bold .. "Nexus Shell - 組み込みコマンド一覧" .. colors.reset .. "\n")
    local list = {
        { "cd [dir|-]",                "ディレクトリを変更する" },
        { "pwd",                       "現在のディレクトリを表示する" },
        { "echo [-n] [args]",          "テキストを出力する" },
        { "printf fmt [args]",         "書式付きで出力する" },
        { "read [-r] [-p p] name...",  "標準入力から1行読む" },
        { "test expr / [ expr ]",      "条件を評価する" },
        { "export / unset / local",    "変数を設定・削除する" },
        { "set [-eux] [-- args]",      "オプションと位置パラメータ" },
        { "shift / return / break / continue", "制御" },
        { "eval / . file / exec",      "コマンドを実行する" },
        { "command / type",            "コマンドの場所を調べる" },
        { "wait [pid]",                "バックグラウンドの終了を待つ" },
        { "env",                       "環境変数一覧を表示する" },
        { "exit [code]",               "シェルを終了する" },
        { "history [-c]",              "コマンド履歴を表示する (-c で消去)" },
        { "help",                      "このヘルプを表示する" },
    }
    for _, row in ipairs(list) do
        out(string.format("  %-34s %s\n", colors.green .. row[1] .. colors.reset, row[2]))
    end
    out("  Control: if/elif/else/fi, while/until/do/done, for/in, case/esac, name() { ... }\n")
    out("  Lists: a; b, a && b, a || b, a | b, a &, ( subshell ), { group; }\n")
    out("  Redirection: < > >> 2> 2>&1 &> <<EOF\n")
    return 0
end

------------------------------------------------------------------------
-- Running source text
------------------------------------------------------------------------

local function report_syntax(err, location)
    io.stderr:write(location .. ":" .. tostring(err.line or "?") .. ": syntax error: "
        .. tostring(err.sh_syntax) .. "\n")
end

-- Runs shell source in this shell, parsing one complete command at a time.
-- Returns the last status and a pending break/continue/return.
function run_text(text, location)
    -- scripts written on Windows end their lines with CR LF
    text = text:gsub("\r\n", "\n")
    local parser = new_parser(new_lexer(text))
    local status = 0
    while true do
        local ok, node = pcall(parser.complete_command, parser)
        if not ok then
            if type(node) == "table" and node.sh_syntax then
                report_syntax(node, location)
                set_status(2)
                return 2
            end
            error(node, 0)
        end
        if not node then return status end
        local ctl
        status, ctl = exec_node(node)
        status = status or 0
        set_status(status)
        if ctl then return status, ctl end
    end
end

-- Interactive and piped input arrive a line at a time. Returns the text
-- still waiting for the rest of an unfinished command, or nil; the second
-- result reports a syntax error.
local function feed_line(pending, line, location)
    local text = (pending or "") .. line:gsub("\r$", "") .. "\n"
    local parser = new_parser(new_lexer(text))
    local nodes = {}
    local ok, err = pcall(function()
        while true do
            local node = parser:complete_command()
            if not node then break end
            nodes[#nodes + 1] = node
        end
    end)
    if not ok then
        if type(err) == "table" and err.sh_syntax then
            if err.incomplete then return text end
            report_syntax(err, location)
            set_status(2)
            return nil, true
        end
        error(err, 0)
    end
    for _, node in ipairs(nodes) do
        local status = exec_node(node)
        set_status(status or 0)
    end
    return nil
end

local function set_script_arguments(name, argv, first)
    scriptName = name
    scriptArgs = {}
    for i = first, #argv do scriptArgs[#scriptArgs + 1] = argv[i] end
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
    local status = 127
    if builtins[name] then status = call_builtin(name, args) end
    os.exit(status)
elseif shell_args[1] == "-c" then
    if shell_args[2] == nil then
        io.stderr:write("sh: -c requires a command\n")
        os.exit(2)
        return
    end
    set_script_arguments(shell_args[3] or "sh", shell_args, 4)
    os.exit((run_text(shell_args[2], shell_args[3] or "sh")))
    return
elseif shell_args[1] == "-s" then
    set_script_arguments("sh", shell_args, 2)
    local pending
    while true do
        local line = io.read("*l")
        if line == nil then break end
        local failed
        pending, failed = feed_line(pending, line, "stdin")
        if failed then os.exit(2) end
    end
    if pending then
        io.stderr:write("stdin: syntax error: unexpected end of file\n")
        os.exit(2)
    end
    os.exit(last_status)
    return
elseif shell_args[1] and shell_args[1] ~= "-l" then
    local first = shell_args[1] == "--" and 2 or 1
    local path = shell_args[first]
    if not path or (first == 1 and path:sub(1, 1) == "-") then
        io.stderr:write("Usage: sh [-l] | sh -c command [name [args...]] | sh -s [args...] | sh [--] script [args...]\n")
        os.exit(2)
        return
    end
    local text, err = read_file(path)
    if not text then
        io.stderr:write("sh: " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(127)
        return
    end
    set_script_arguments(path, shell_args, first + 1)
    os.exit((run_text(text, path)))
    return
end

-- Tab completion: command names for the first word, paths otherwise.
local function complete(before)
    local word = before:match("(%S*)$")
    local head = before:sub(1, #before - #word)
    local result, seen = {}, {}
    local function add(s)
        if not seen[s] then
            seen[s] = true
            result[#result + 1] = head .. s
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
        for name in pairs(functions) do
            if name:sub(1, #word) == word then add(name) end
        end
        local path_env = os.getenv("PATH") or "/usr/ubin:/usr/bin:/bin"
        for dir in path_env:gmatch("[^:]+") do
            for name in list(dir) do
                name = name:gsub("/$", ""):gsub("%.lua$", "")
                if name:sub(1, #word) == word then add(name) end
            end
        end
        if #result == 1 then result[1] = result[1] .. " " end
        return result
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
    if #result == 1 and not result[1]:find("/$") then result[1] = result[1] .. " " end
    return result
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

is_interactive = interactive()

-- An interactive shell leads its own process group, so Ctrl+C reaches the
-- commands it runs (they inherit the group) and not the processes that
-- started it. It catches SIGINT and SIGQUIT itself, like other Unix
-- shells: a caught signal reverts to the default in commands it starts.
if is_interactive and process.signal then
    if process.setpgid then process.setpgid(0, 0) end
    process.signal(2, function() end)
    process.signal(3, function() end)
end

local pending
while true do
    if pending then io.write(os.getenv("PS2") or "> ") else io.write(get_prompt()) end

    local line
    if is_interactive then
        line = io.read("*l", { history = shell_history, historyLimit = HISTORY_LIMIT, complete = complete })
    else
        line = io.read()
    end
    if not line then
        -- EOF (Ctrl+D)
        if pending then
            io.stderr:write("sh: syntax error: unexpected end of file\n")
            set_status(2)
        end
        print("exit")
        os.exit(last_status)
    end

    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and is_interactive then remember(trimmed) end
    if pending or trimmed ~= "" then
        pending = feed_line(pending, line, "sh")
    end

    coroutine.yield()
end
