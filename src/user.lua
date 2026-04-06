---@class user
user = {}

---@class user_shadow
---@field username string
---@field password string
---@field last_change number|nil
---@field min_days number|nil
---@field max_days number|nil
---@field warn_days number|nil
---@field inactive_days number|nil
---@field expire_date number|nil
---@field reserved string|nil

---@class user_passwd
---@field username string
---@field password string
---@field uid number
---@field gid number
---@field gecos string
---@field home string
---@field shell string

user._users = {}

local function user_getShadows()
    local handle, err = vfs.open("/etc/shadow", "r")
    if not handle then return nil, err end

    local content = handle:readAll()
    handle:close()

    local shadows = {}
    for line in content:gmatch("[^\r\n]+") do
        local u, p, last, min, max, warn, inactive, expire, reserved =
            line:match("^([^:]+):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):?(.*)")

        if u then
            table.insert(shadows, {
                username = u,
                password = p,
                last_change = tonumber(last) or nil,
                min_days = tonumber(min) or nil,
                max_days = tonumber(max) or nil,
                warn_days = tonumber(warn) or nil,
                inactive_days = tonumber(inactive) or nil,
                expire_date = tonumber(expire) or nil,
                reserved = reserved ~= "" and reserved or nil
            })
        end
    end

    return shadows
end

local function user_getShadow(username)
    local shadows, err = user_getShadows()
    if not shadows then return nil, err end

    for _, entry in ipairs(shadows) do
        if entry.username == username then
            return entry
        end
    end

    return nil, "user not found"
end

function user.checkRoot()
    ---@type user_passwd
    local usr = user.getCurrent() or { uid = 0, gid = 0 }
    return usr.uid == 0 or usr.gid == 0
end

function user.updateUsers()
    local file = vfs.open("/etc/passwd", "r")
    if not file then return nil, "cannot open /etc/passwd" end

    local content = file:readAll()
    file:close()

    local users = {}
    for line in content:gmatch("[^\r\n]+") do
        local username, password, uid, gid, gecos, home, shell = line:match(
            "^([^:]+):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")

        if username then
            table.insert(users, {
                username = username,
                password = password,
                uid = tonumber(uid),
                gid = tonumber(gid),
                gecos = gecos,
                home = home,
                shell = shell
            })
        end
    end

    user._users = users
end

function user.getUser(username)
    for _, entry in ipairs(user._users) do
        if entry.username == username then
            return entry
        end
    end

    return nil, "user not found"
end

function user.create(username, password, uid, gid, gecos, shell)
    uid = uid or 100
    gid = gid or uid

    if not group.getGroupByGID(uid) then
        group.create(username, gid, { username })
    end

    gecos = gecos or ""
    shell = shell or "/bin/sh.lua"

    local passwd_line = table.concat({
        username,
        "x",
        tostring(uid),
        tostring(gid),
        gecos,
        "/home/" .. username,
        shell,
    }, ":")

    local hash = toHex(sha512(password))
    -- Using base.getRealTime if available, else os.time
    local last_change = math.floor(os.time())
    local min_days = 0
    local max_days = 99999
    local warn_days = 7
    local inactive_days = ""
    local expire_date = ""
    local reserved = ""

    local shadow_line = table.concat({
        username,
        hash,
        tostring(last_change),
        tostring(min_days),
        tostring(max_days),
        tostring(warn_days),
        inactive_days,
        expire_date,
        reserved,
    }, ":")


    local shadow_file, e = vfs.open("/etc/shadow", "a")
    if not shadow_file then return nil, "cannot open /etc/shadow: " .. e end
    shadow_file:write(shadow_line .. "\n")
    shadow_file:close()

    local passwd_file, e = vfs.open("/etc/passwd", "a")
    if not passwd_file then return nil, "cannot open /etc/passwd: " .. e end
    passwd_file:write(passwd_line .. "\n")
    passwd_file:close()

    user.updateUsers()

    local home = vfs.concat("/home", username)
    vfs.makeDirectory(home)
    vfs.chown(home, uid, gid)
    do
        local prof = vfs.concat(home, ".profile.lua")
        local f, e = vfs.open(prof, "w")
        if f then
            f:write("local colors = require(\"colors\")\n")
            f:write("local shell = require(\"shell\")\n")
            f:write("os.setenv(\"HISTSIZE\", \"10\")\n")
            f:write("os.setenv(\"HOME\", \"" .. home .. "\")\n")
            f:write("os.setenv(\"PS1\", colors.green .. \"$USERNAME@$HOSTNAME\" .. colors.reset .. \":\" .. colors.bright_blue .. \"$PWD\" .. colors.reset .. \"$ \")\n")
            f:write("shell.setWorkingDirectory(os.getenv(\"HOME\"))")
            f:close()
        else
            printk("user: create: cannot open '" .. prof .. "': " .. e)
        end
        vfs.chown(prof, uid, gid)
    end
end

function user.getUserByUID(uid)
    for _, entry in ipairs(user._users) do
        if entry.uid == uid then
            return entry
        end
    end

    return nil, "user not found"
end

function user.checkPasswordCorrect(username, passwd)
    local passwd_hash = toHex(sha512(passwd))
    local shadow = user_getShadow(username)
    if shadow and shadow.password == passwd_hash then
        return true
    end
    return false
end

---@return user_passwd?
function user.getCurrent()
    local proc = process.getCurrent()
    if not proc then return nil end
    return user.getUserByUID(proc.uid)
end

---@return user_passwd|nil, nil|string
function user.switchuser(username, password)
    if user.checkPasswordCorrect(username, password) then
        ---@type user_passwd
        local usr = user.getUser(username) --[[@as user_passwd]]
        if not usr then return nil, "User not found" end

        process.setEnviron("HOME", usr.home)
        process.setEnviron("USER", usr.username)
        process.setEnviron("SHELL", usr.shell)

        return usr
    else
        return nil, "Authentication failed"
    end
end

---@return user_passwd|nil, nil|string
function user.switchprocuser(username, password, pid)
    if user.checkPasswordCorrect(username, password) then
        ---@type user_passwd
        local usr = user.getUser(username) --[[@as user_passwd]]
        if not usr then return nil, "User not found" end

        local proc = process.get(pid)
        if not proc then return nil, "Process not found" end
        proc.uid = usr.uid
        proc.euid = usr.uid
        proc.suid = usr.uid
        proc.gid = usr.gid
        proc.egid = usr.gid
        proc.sgid = usr.gid

        process.setEnviron("HOME", usr.home)
        process.setEnviron("USER", usr.username)
        process.setEnviron("SHELL", usr.shell)

        return usr
    else
        return nil, "Authentication failed"
    end
end

function user.init()
    local root_passwd_line = "root:x:0:0:root:/root:/bin/sh.lua\n"
    local root_shadow_line = "root:*:0:0:99999:7:::\n"

    if not vfs.exists("/etc/passwd") then
        local file = vfs.open("/etc/passwd", "w")
        file:write(root_passwd_line)
        file:close()
    end
    if not vfs.exists("/etc/shadow") then
        local file = vfs.open("/etc/shadow", "w")
        file:write(root_shadow_line)
        file:close()
    end

    vfs.chmod("/etc/shadow", 400)
    user.updateUsers()
end
