-- A deliberately small, fail-closed sudo implementation. Supported policy
-- entries are: user ALL=(root|ALL) ALL and %group ALL=(root|ALL) ALL.
local process = require("process")
local filesystem = require("filesystem")
local user = require("user")

local function fail(message, code)
    io.stderr:write("sudo: " .. message .. "\n")
    os.exit(code or 1)
end

local argv = { ... }
for index = 1, #argv do
    if type(argv[index]) ~= "string" then fail("arguments must be strings", 2) end
end

local current = process.getCurrent()
if not current then fail("cannot identify caller") end
if current.euid ~= 0 then fail("set-user-ID privilege is unavailable") end

local function isWritable(digit)
    return digit % 4 >= 2
end

local function unsafeMode(mode)
    local group_digit = math.floor(mode / 10) % 10
    local other_digit = mode % 10
    return isWritable(group_digit) or isWritable(other_digit)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readTrustedFile(path)
    local attr = filesystem.attributes(path)
    if not attr or attr.type ~= "VREG" or attr.uid ~= 0 or type(attr.mode) ~= "number"
        or unsafeMode(attr.mode) then
        return nil, path .. " is missing or has unsafe ownership/permissions"
    end
    local handle, err = filesystem.open(path, "r")
    if not handle then return nil, "cannot read " .. path .. ": " .. tostring(err) end
    local content = handle:readAll()
    handle:close()
    if type(content) ~= "string" then return nil, "cannot read " .. path end
    return content
end

local function passwdEntryByUID(content, uid)
    for line in content:gmatch("[^\r\n]+") do
        local name, _, entry_uid, gid, gecos, home, shell = line:match(
            "^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]*):([^:]*)$")
        if tonumber(entry_uid) == uid then
            return {
                username = name, uid = tonumber(entry_uid), gid = tonumber(gid),
                gecos = gecos, home = home, shell = shell,
            }
        end
    end
end

local passwd_content, passwd_error = readTrustedFile("/etc/passwd")
if not passwd_content then fail(passwd_error) end
local caller = passwdEntryByUID(passwd_content, current.uid)
if not caller then fail("cannot identify caller account") end
local root_user = passwdEntryByUID(passwd_content, 0)
if not root_user then fail("root account is unavailable") end

-- Load the bundled parser only after checking that its fixed system path is
-- root-owned and not writable by group or others. Never use require's search path.
local argparse_source, argparse_error = readTrustedFile("/usr/lib/argparse.lua")
if not argparse_source then fail(argparse_error) end
local argparse_chunk, argparse_load_error = load(argparse_source, "@/usr/lib/argparse.lua", "t", _ENV)
if not argparse_chunk then fail("cannot load argument parser: " .. tostring(argparse_load_error)) end
local argparse = argparse_chunk()
local parser = argparse("sudo"):add_help(false)
parser:description("Run an allowed command as root. Passwords are checked against your own account.")
parser:flag("-h --help", "Show this help message.")
parser:argument("command"):args("?")
parser:argument("arguments"):args("*")

-- Stop sudo option parsing at the first command, so command flags such as
-- --help are forwarded unchanged. An explicit user-provided -- stays intact.
local parse_argv, command_seen = {}, false
for index, value in ipairs(argv) do
    if not command_seen then
        if value == "--" then
            command_seen = true
            parse_argv[#parse_argv + 1] = value
        elseif value:sub(1, 1) == "-" then
            parse_argv[#parse_argv + 1] = value
        else
            command_seen = true
            parse_argv[#parse_argv + 1] = value
            parse_argv[#parse_argv + 1] = "--"
        end
    else
        parse_argv[#parse_argv + 1] = value
    end
end
local parsed = parser:parse(parse_argv)
if parsed.help then
    io.write(parser:get_help())
    return
end
if not parsed.command then
    io.write(parser:get_usage())
    fail("command required", 2)
end

local function readPolicy()
    local content, err = readTrustedFile("/etc/sudoers")
    if not content then return nil, err end

    local rules = {}
    for line in content:gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local principal, runas, command = line:match("^(%S+)%s+ALL%s*=%s*%(([^)]+)%)%s+(%S+)%s*$")
            if not principal or not principal:match("^%%?[A-Za-z_][A-Za-z0-9_.-]*$")
                or (runas ~= "root" and runas ~= "ALL") or command ~= "ALL" then
                return nil, "unsupported or invalid policy rule"
            end
            rules[#rules + 1] = { principal = principal, runas = runas }
        end
    end
    return rules
end

local rules, policy_error = readPolicy()
if not rules then fail(policy_error) end

local group_content, group_error = readTrustedFile("/etc/group")
if not group_content then fail(group_error) end
local function groupMatches(name)
    for line in group_content:gmatch("[^\r\n]+") do
        local group_name, gid, members = line:match("^([^:]+):([^:]+):([^:]*)$")
        if group_name == name then
            if tonumber(gid) == caller.gid then return true end
            for member in members:gmatch("[^,]+") do
                if member == caller.username then return true end
            end
        end
    end
    return false
end

local allowed = false
for _, rule in ipairs(rules) do
    if rule.principal == caller.username then
        allowed = true
    elseif rule.principal:sub(1, 1) == "%" and groupMatches(rule.principal:sub(2)) then
        allowed = true
    end
end
if not allowed then fail("" .. caller.username .. " is not allowed by /etc/sudoers") end

if current.uid ~= 0 then
    local authenticated = false
    for _ = 1, 3 do
        io.write("[sudo] password for " .. caller.username .. ": ")
        local password = io.read("*l", "*")
        io.write("\n")
        if password == nil then break end
        if user.checkPasswordCorrect(caller.username, password) then
            authenticated = true
            break
        end
        io.stderr:write("Sorry, try again.\n")
    end
    if not authenticated then fail("authentication failed") end
end

local ok, err = process.setuser(root_user)
if not ok then fail("cannot switch to root: " .. tostring(err)) end

local environ = process.getEnviron()
if type(environ) == "table" then
    local keys = {}
    for key in pairs(environ) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do process.setEnviron(key, nil) end
end
local root_cwd = process.cwd()
process.setEnviron("HOME", root_user.home)
process.setEnviron("USER", root_user.username)
process.setEnviron("USERNAME", root_user.username)
process.setEnviron("UID", tostring(root_user.uid))
process.setEnviron("SHELL", root_user.shell)
process.setEnviron("PATH", "/usr/bin:/usr/sbin:/usr/ubin:/bin:/sbin:/ubin")
process.setEnviron("PWD", root_cwd)
process.setEnviron("SUDO_USER", caller.username)
process.setEnviron("SUDO_UID", tostring(caller.uid))
process.setEnviron("SUDO_GID", tostring(caller.gid))

local function findCommand(command)
    local candidates = {}
    if command:find("/", 1, true) then
        candidates[1] = command
    else
        for _, directory in ipairs({ "/usr/bin", "/usr/sbin", "/usr/ubin", "/bin", "/sbin", "/ubin" }) do
            candidates[#candidates + 1] = directory .. "/" .. command
        end
    end
    local expanded = {}
    for _, candidate in ipairs(candidates) do
        expanded[#expanded + 1] = candidate
        if candidate:sub(-4) ~= ".lua" then expanded[#expanded + 1] = candidate .. ".lua" end
    end
    for _, candidate in ipairs(expanded) do
        if filesystem.exists(candidate) and not filesystem.isDirectory(candidate) then
            return candidate
        end
    end
end

local command = parsed.command
local path = findCommand(command)
if not path then fail("command not found: " .. command, 127) end
local command_args = parsed.arguments or {}
local pid, exec_error = process.exec(path, command_args)
if not pid or pid == -1 then
    fail("cannot execute " .. command .. ": " .. tostring(exec_error), 126)
end
local wait_error = process.wait(pid)
if wait_error then fail("process error: " .. tostring(wait_error)) end
