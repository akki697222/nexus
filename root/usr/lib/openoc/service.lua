-- OpenOC service definition reader. Declarative files are parsed as data.
local fs = require("filesystem")
local M = {}
local INIT_DIR = "/etc/init.d"

local function validName(name)
    return type(name) == "string" and name:match("^[%w_][%w_%-]*$") ~= nil
end

local function regularFile(path)
    local ok, attributes = pcall(fs.attributes, path)
    return ok and attributes ~= nil and attributes.type == "VREG"
end

function M.find(name)
    if not validName(name) then return nil, "Invalid service name" end
    local path = INIT_DIR .. "/" .. name
    local ok, attributes = pcall(fs.attributes, path)
    if ok and attributes then
        if attributes.type == "VREG" then return path end
        return nil, "Service definition is not a regular file"
    end
    path = path .. ".lua"
    if regularFile(path) then return path end
    return nil, "Service definition not found"
end

local function decodeScalar(value)
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return "" end
    local quote = value:sub(1, 1)
    if quote ~= "'" and quote ~= '"' then
        if value:find("['\"\\]", 1) then return nil, "Malformed quoted value" end
        return value
    end
    if value:sub(-1) ~= quote then return nil, "Unterminated quoted value" end
    local out, i = {}, 2
    while i < #value do
        local char = value:sub(i, i)
        if char == quote then return nil, "Trailing text after quoted value" end
        if char == "\\" and quote == '"' then
            i = i + 1
            if i >= #value then return nil, "Trailing escape in quoted value" end
            char = value:sub(i, i)
        end
        out[#out + 1] = char
        i = i + 1
    end
    return table.concat(out)
end

local function tokenize(text)
    local args, token, active, quote = {}, {}, false, nil
    local i = 1
    while i <= #text do
        local char = text:sub(i, i)
        if char == "$" or char == string.char(96) then
            return nil, "Shell substitutions are not allowed"
        elseif quote == "'" then
            if char == "'" then quote = nil else token[#token + 1] = char end
            active = true
        elseif quote == '"' then
            if char == '"' then
                quote = nil
            elseif char == "\\" then
                i = i + 1
                if i > #text then return nil, "Trailing escape in command_args" end
                token[#token + 1] = text:sub(i, i)
            else
                token[#token + 1] = char
            end
            active = true
        elseif char == "'" or char == '"' then
            quote, active = char, true
        elseif char == "\\" then
            i = i + 1
            if i > #text then return nil, "Trailing escape in command_args" end
            token[#token + 1] = text:sub(i, i)
            active = true
        elseif char:match("%s") then
            if active then args[#args + 1] = table.concat(token); token, active = {}, false end
        elseif char:match("[;|&<>()]") then
            return nil, "Shell control syntax is not allowed in command_args"
        else
            token[#token + 1], active = char, true
        end
        i = i + 1
    end
    if quote then return nil, "Unterminated quote in command_args" end
    if active then args[#args + 1] = table.concat(token) end
    return args
end

local function validAbsolutePath(path)
    return type(path) == "string" and path:sub(1, 1) == "/"
end

local function validDeclarativePath(path)
    return validAbsolutePath(path) and path ~= "/" and not path:find("%c")
end

local function readDeclarative(path, name)
    local file, err = fs.open(path, "r")
    if not file then return nil, err end
    local ok, source = pcall(function()
        if type(file.readAll) == "function" then return file:readAll() end
        return file:read("*a")
    end)
    pcall(file.close, file)
    if not ok then return nil, source end
    if type(source) ~= "string" then return nil, "Unable to read service definition" end
    source = source:gsub("\r\n", "\n")
    local first, rest = source:match("^([^\n]*)\n?(.*)$")
    if first ~= "#!/sbin/openoc-run" then return nil, "Invalid service shebang" end

    local values = {}
    local lineNumber = 1
    for line in (rest .. "\n"):gmatch("(.-)\n") do
        lineNumber = lineNumber + 1
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local key, raw = trimmed:match("^([%a_][%w_]*)%s*=%s*(.-)%s*$")
            if not key then return nil, "Malformed service definition at line " .. lineNumber end
            if key ~= "command" and key ~= "description" and key ~= "command_args" and key ~= "type" then
                return nil, "Unknown service key: " .. key
            end
            if values[key] ~= nil then return nil, "Duplicate service key: " .. key end
            local value, valueErr = decodeScalar(raw)
            if value == nil then return nil, valueErr .. " at line " .. lineNumber end
            values[key] = value
        end
    end
    if not values.command then return nil, "Missing required command" end
    if not validDeclarativePath(values.command) then return nil, "Invalid absolute command path" end
    local kind = values.type or "daemon"
    if kind ~= "oneshot" and kind ~= "daemon" then return nil, "Invalid service type" end
    local args, argsErr = tokenize(values.command_args or "")
    if not args then return nil, argsErr end
    local title = name or path:match("([^/]+)$") or path
    return { title = title, desc = values.description or title, execpath = values.command,
        args = args, oneshot = kind == "oneshot" }
end

local function readLegacy(path)
    local chunk, err = loadfile(path, "t")
    if not chunk then return nil, err end
    local ok, definition = pcall(chunk, path)
    if not ok then return nil, definition end
    if type(definition) ~= "table" or definition.service ~= "program"
        or type(definition.title) ~= "string" or type(definition.desc) ~= "string"
        or not validAbsolutePath(definition.execpath)
        or (definition.args ~= nil and type(definition.args) ~= "table") then
        return nil, "Invalid program service definition"
    end
    return { title = definition.title, desc = definition.desc, execpath = definition.execpath,
        args = definition.args or {}, oneshot = false }
end

function M.read(path, name)
    if type(path) ~= "string" then return nil, "Invalid service definition path" end
    if path:sub(-4) == ".lua" then return readLegacy(path) end
    return readDeclarative(path, name)
end

return M
