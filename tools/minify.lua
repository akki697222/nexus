-- tools/minify.lua - makes Lua source smaller without changing what it does
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   local minify = loadfile("tools/minify.lua")()
--   local small = minify(source)
--
-- Comments, indentation, line breaks and the spaces between tokens are
-- dropped; strings (long brackets included) are kept byte for byte. Lua 5.2
-- and later read a line break as any other space, so the result is one long
-- line that does the same. Names are not shortened. Host-side tool (Lua
-- 5.3+), used by tools/mkinstaller.lua: the installer has to fit OpenOS's
-- 64 KB tmpfs. With keepLines, a line break stays wherever the source had
-- one between two tokens (error positions then name the right line).

local OPS = {}
for _, op in ipairs({ "...", "..", "==", "~=", "<=", ">=", "<<", ">>", "//", "::" }) do OPS[op] = true end

-- the end of a long bracket opened at i ([[, [=[, ...), or nil
local function longBracket(src, i)
    local eq = src:match("^%[(=*)%[", i)
    if not eq then return nil end
    local close = "]" .. eq .. "]"
    local _, stop = src:find(close, i + #eq + 2, true)
    if not stop then error("unfinished long bracket at byte " .. i, 0) end
    return stop
end

-- Splits src into tokens: { text, newlineBefore }.
local function tokens(src)
    local out, i, n, newline = {}, 1, #src, false
    local function push(text)
        out[#out + 1] = { text, newline }
        newline = false
    end
    while i <= n do
        local c = src:sub(i, i)
        if c == "\n" then
            newline = true
            i = i + 1
        elseif c:match("%s") then
            i = i + 1
        elseif src:sub(i, i + 1) == "--" then
            local stop = longBracket(src, i + 2)
            if stop then
                -- a long comment counts as a line break if it spans lines
                if src:sub(i, stop):find("\n", 1, true) then newline = true end
                i = stop + 1
            else
                local eol = src:find("\n", i, true)
                i = eol or n + 1
            end
        elseif c == "[" and longBracket(src, i) then
            local stop = longBracket(src, i)
            push(src:sub(i, stop))
            i = stop + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while true do
                local d = src:sub(j, j)
                if d == "" or d == "\n" then error("unfinished string at byte " .. i, 0) end
                if d == "\\" then
                    -- an escaped line break, or \z and the whitespace after it
                    if src:sub(j + 1, j + 1) == "z" then
                        j = select(2, src:find("^%s*", j + 2)) + 1
                    else
                        j = j + 2
                    end
                elseif d == c then
                    break
                else
                    j = j + 1
                end
            end
            push(src:sub(i, j))
            i = j + 1
        elseif c:match("[%a_]") then
            local stop = select(2, src:find("^[%w_]*", i + 1))
            push(src:sub(i, stop))
            i = stop + 1
        elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
            local stop
            if src:match("^0[xX]", i) then
                stop = select(2, src:find("^0[xX][%x%.]*", i))
                stop = select(2, src:find("^[pP][%+%-]?%d+", stop + 1)) or stop
            else
                stop = select(2, src:find("^[%d%.]*", i))
                stop = select(2, src:find("^[eE][%+%-]?%d+", stop + 1)) or stop
            end
            push(src:sub(i, stop))
            i = stop + 1
        else
            local three, two = src:sub(i, i + 2), src:sub(i, i + 1)
            if OPS[three] then
                push(three)
                i = i + 3
            elseif OPS[two] then
                push(two)
                i = i + 2
            else
                push(c)
                i = i + 1
            end
        end
    end
    return out
end

local function word(ch) return ch:match("[%w_]") ~= nil end

-- Whether two tokens need a space between them to stay two tokens.
local function needSpace(a, b)
    local last, first = a:sub(-1), b:sub(1, 1)
    if word(last) and word(first) then return true end
    if last == "-" and first == "-" then return true end
    -- "1 .." and "a.b . .5": a dot next to a number or another dot
    if (last == "." or a:match("^%.?%d")) and (first == "." or first:match("%d")) then return true end
    if last == "[" and (first == "[" or first == "=") then return true end
    if OPS[last .. first] then return true end
    return false
end

return function(src, keepLines)
    local list = tokens(src)
    local out = {}
    for k, t in ipairs(list) do
        if k > 1 then
            if t[2] and keepLines then
                out[#out + 1] = "\n"
            elseif needSpace(list[k - 1][1], t[1]) then
                out[#out + 1] = " "
            end
        end
        out[#out + 1] = t[1]
    end
    return table.concat(out) .. "\n"
end
