---@class util
local util = {}

function util.encodeTable(tbl, noreturn)
    local buffer = {}
    local i = 0
    local function write(str)
        i = i + 1
        buffer[i] = str
    end

    local function encode(tbl)
        write("{")
        for key, value in pairs(tbl) do
            local t = type(value)
            local keystr

            if type(key) == "number" then
                keystr = "[" .. key .. "]="
            elseif type(key) == "string" then
                if key:find("[^%w_]") or key:match("^%d") then
                    keystr = "[\"" .. key .. "\"]="
                else
                    keystr = key .. "="
                end
            elseif key == nil then
                keystr = "nil"
            else
                error("Cannot encode key of type: " .. type(key))
            end

            write(keystr)

            if t == "number" then
                write(tostring(value))
            elseif t == "string" then
                write("\"" .. value .. "\"")
            elseif t == "boolean" then
                write(value and "true" or "false")
            elseif t == "table" then
                encode(value)
            else
                error("Cannot encode value of type: " .. t)
            end

            write(",")
        end
        write("}")
    end

    if not noreturn then write("return") end
    encode(tbl)

    local result = ""
    for idx = 1, i do
        result = result .. buffer[idx]
    end
    return result
end

function util.copyTable(tbl)
    if not tbl then return {} end
    local copy = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            copy[k] = util.copyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

util.createEnv = function()
    return {}
end
