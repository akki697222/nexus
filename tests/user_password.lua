-- Tests for user.hasPassword and user.setPassword (src/user.lua).
-- Run from the Nexus directory: lua tests/user_password.lua
local sourceFile = assert(io.open("src/user.lua", "r"))
local source = sourceFile:read("*a")
sourceFile:close()

local files = {
    ["/etc/passwd"] = "root:x:0:0:root:/root:/bin/sh.lua\n"
        .. "alice:x:100:100::/home/alice:/bin/sh.lua\n",
    ["/etc/shadow"] = "root:*:0:0:99999:7:::\n",
}
local current = { uid = 0, euid = 0 }

local function handle(path, mode)
    local buffer = {}
    return {
        readAll = function() return files[path] end,
        write = function(_, data) buffer[#buffer + 1] = data end,
        close = function()
            if mode == "w" then files[path] = table.concat(buffer) end
        end,
    }
end

local env = setmetatable({
    process = { getCurrent = function() return current end },
    util = {
        copyTable = function(entry)
            local copy = {}
            for key, value in pairs(entry) do copy[key] = value end
            return copy
        end,
    },
    -- a stand-in hash: the tests only need it to be deterministic
    sha512 = function(data) return "H(" .. data .. ")" end,
    toHex = function(data) return (data:gsub("[^%w]", "_")) end,
    vfs = {
        exists = function(path) return files[path] ~= nil end,
        open = function(path, mode)
            if mode ~= "w" and files[path] == nil then return nil, "No such file or directory" end
            return handle(path, mode)
        end,
    },
}, { __index = _G })

assert(load(source, "@src/user.lua", "t", env))()
local user = env.user
user.updateUsers()

local function shadowLine(name)
    for line in files["/etc/shadow"]:gmatch("[^\n]+") do
        if line:match("^([^:]+):") == name then return line end
    end
end

-- 1. A locked root ("*") and a user without a shadow entry have no password.
assert(user.hasPassword("root") == false)
assert(user.hasPassword("alice") == false)
assert(user.hasPassword("nobody") == false)

-- 2. Root sets root's password: the entry is rewritten in place, the aging
--    fields are kept and the last change is updated.
assert(user.setPassword("root", "secret") == true)
local root = shadowLine("root")
assert(root:match("^root:H_secretsalt_:%d+:0:99999:7:::$"), root)
assert(user.hasPassword("root") == true)
assert(user.checkPasswordCorrect("root", "secret"))
assert(not user.checkPasswordCorrect("root", "wrong"))

-- 3. A user without a shadow entry gets one appended; others are kept.
assert(user.setPassword("alice", "pw") == true)
assert(shadowLine("alice"):match("^alice:H_pwsalt_:%d+:0:99999:7:::$"))
assert(shadowLine("root") == root)
assert(user.checkPasswordCorrect("alice", "pw"))

-- 4. "!" (locked with a hash) and an empty field are not passwords either.
files["/etc/shadow"] = "root:!H_secretsalt_:0:0:99999:7:::\nalice::0:0:99999:7:::\n"
assert(user.hasPassword("root") == false and user.hasPassword("alice") == false)

-- 5. Unknown users and empty passwords are refused, nothing is written.
local before = files["/etc/shadow"]
local ok, err = user.setPassword("nobody", "x")
assert(ok == nil and err == "user not found")
ok, err = user.setPassword("root", "")
assert(ok == nil and err == "empty password")
assert(files["/etc/shadow"] == before)

-- 6. Only root may set passwords or look at them.
current = { uid = 100, euid = 100 }
ok, err = user.setPassword("alice", "mine")
assert(ok == nil and err == "Permission denied")
assert(files["/etc/shadow"] == before)
files["/etc/shadow"] = "root:H_secretsalt_:0:0:99999:7:::\n"
assert(user.hasPassword("root") == false, "non-root must not learn about shadow entries")

print("user password tests passed")
