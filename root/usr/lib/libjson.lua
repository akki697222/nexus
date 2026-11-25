-- libjson.lua - JSON for programs: require("json")
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   json.encode(value)     -> string (object keys sorted)
--   json.decode(text)      -> value, or nil and why
--   json.null              stands for null both ways
--   json.array(t)          marks t as an array, so an empty one is [] not {}
--
-- Integers stay integers both ways; strings are UTF-8, \u escapes
-- (surrogate pairs too) are decoded.

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end, __metatable = "json.null" })

local ARRAY = { __metatable = "json.array" }

function json.array(t)
    return setmetatable(t or {}, ARRAY)
end

local ESCAPE = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESCAPE[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

-- whether t is a list 1..n (an empty table is an object unless marked)
local function isArray(t)
    if getmetatable(t) == "json.array" then return true end
    local n = #t
    if n == 0 then return false end
    local count = 0
    for k in pairs(t) do
        if math.type(k) ~= "integer" or k < 1 or k > n then return false end
        count = count + 1
    end
    return count == n
end

local encode

local function encodeTable(t, seen)
    if seen[t] then error("json: cannot encode a cycle", 0) end
    seen[t] = true
    local out = {}
    if isArray(t) then
        for i = 1, #t do out[i] = encode(t[i], seen) end
        seen[t] = nil
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(t) do
        if type(k) ~= "string" then error("json: object keys must be strings", 0) end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do out[i] = encodeString(k) .. ":" .. encode(t[k], seen) end
    seen[t] = nil
    return "{" .. table.concat(out, ",") .. "}"
end

encode = function(v, seen)
    local t = type(v)
    if v == nil or v == json.null then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json: cannot encode " .. tostring(v), 0) end
        if math.type(v) == "integer" then return string.format("%d", v) end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%.1f", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then return encodeString(v) end
    if t == "table" then return encodeTable(v, seen) end
    error("json: cannot encode a " .. t, 0)
end

function json.encode(v)
    return encode(v, {})
end

-- decoding --------------------------------------------------------------

local function fail(text, pos, what)
    local line = select(2, text:sub(1, pos):gsub("\n", "")) + 1
    error({ json = "json: " .. what .. " at line " .. line .. " (byte " .. pos .. ")" }, 0)
end

local function skip(text, pos)
    return (select(2, text:find("^[ \t\r\n]*", pos))) + 1
end

local decodeValue

local function decodeString(text, pos)
    local out, i = {}, pos + 1
    while true do
        local j = text:find('["\\%c]', i)
        if not j then fail(text, pos, "unfinished string") end
        out[#out + 1] = text:sub(i, j - 1)
        local c = text:sub(j, j)
        if c == '"' then return table.concat(out), j + 1 end
        if c ~= "\\" then fail(text, j, "control character in string") end
        local e = text:sub(j + 1, j + 1)
        local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
        if simple then
            out[#out + 1] = simple
            i = j + 2
        elseif e == "u" then
            local hex = text:match("^%x%x%x%x", j + 2)
            if not hex then fail(text, j, "bad \\u escape") end
            local code = tonumber(hex, 16)
            i = j + 6
            if code >= 0xD800 and code <= 0xDBFF then
                local low = text:match("^\\u(%x%x%x%x)", i)
                local lo = low and tonumber(low, 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                    i = i + 6
                end
            end
            out[#out + 1] = utf8.char(code)
        else
            fail(text, j, "bad escape")
        end
    end
end

local function decodeNumber(text, pos)
    local s = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s or s == "-" then fail(text, pos, "bad number") end
    local v = tonumber(s)
    if not v then fail(text, pos, "bad number") end
    if not s:find("[.eE]") then v = math.tointeger(v) or v end
    return v, pos + #s
end

decodeValue = function(text, pos, depth)
    if depth > 200 then fail(text, pos, "nested too deeply") end
    pos = skip(text, pos)
    local c = text:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            if text:sub(pos, pos) ~= '"' then fail(text, pos, "expected a key") end
            local key
            key, pos = decodeString(text, pos)
            pos = skip(text, pos)
            if text:sub(pos, pos) ~= ":" then fail(text, pos, "expected ':'") end
            obj[key], pos = decodeValue(text, pos + 1, depth + 1)
            pos = skip(text, pos)
            local d = text:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then fail(text, pos, "expected ',' or '}'") end
            pos = skip(text, pos + 1)
        end
    elseif c == "[" then
        local arr = json.array({})
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            arr[#arr + 1], pos = decodeValue(text, pos, depth + 1)
            pos = skip(text, pos)
            local d = text:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then fail(text, pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decodeString(text, pos)
    elseif c == "-" or c:match("%d") then
        return decodeNumber(text, pos)
    elseif text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif text:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    end
    fail(text, pos, c == "" and "unexpected end" or "unexpected '" .. c .. "'")
end

-- Returns the value, or nil and why: the text comes from outside.
function json.decode(text)
    if type(text) ~= "string" then return nil, "json: not a string" end
    local ok, value, pos = pcall(decodeValue, text, 1, 0)
    if not ok then
        if type(value) == "table" and value.json then return nil, value.json end
        error(value, 0)
    end
    pos = skip(text, pos)
    if pos <= #text then return nil, "json: trailing data at byte " .. pos end
    return value
end

return json
