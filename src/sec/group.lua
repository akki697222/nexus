-----------------
--- Group API ---
-----------------

---@class group
group = {}

---@class user_group
---@field name string
---@field gid integer
---@field members string[]

---@type user_group[]
group._groups = {}

local function group_load_group()
    if not vfs.exists("/etc/group") then return end

    local file = vfs.open("/etc/group", "r")
    if not file then
        -- panic("group initialize error", err)
        return
    end
    local content = file:readAll()
    file:close()

    local groups = {}
    for line in content:gmatch("[^\r\n]+") do
        local groupname, groupid, member_str = line:match("^([^:]+):([^:]*):([^:]*)$")
        if groupname and groupid then
            local members = {}
            for member in member_str:gmatch("([^,]+)") do
                if member ~= "" then
                    table.insert(members, member)
                end
            end
            table.insert(groups, {
                name = groupname,
                gid = tonumber(groupid),
                members = members
            })
        end
    end

    group._groups = groups
end

function group.updateGroups()
    if not vfs.exists("/etc/group") then
        return nil, "/etc/group does not exist"
    end

    return group_load_group()
end

function group.addUser(groupname, username)
    if not user.getUser(username) then
        error("User " .. username .. " does not exists.")
    else
        local gr = group.getGroup(groupname)
        if not gr then error("Group " .. groupname .. " does not exist") end

        -- Check if already member
        for _, m in ipairs(gr.members) do
            if m == username then return end
        end

        table.insert(gr.members, username)

        -- Write back to /etc/group
        -- This is a bit inefficient to rewrite whole file but okay for now
        local content = ""
        for _, g in ipairs(group._groups) do
            content = content .. g.name .. ":" .. g.gid .. ":" .. table.concat(g.members, ",") .. "\n"
        end

        local file = vfs.open("/etc/group", "w")
        if file then
            file:write(content)
            file:close()
        end
        group.updateGroups()
    end
end

function group.create(groupname, gid, users)
    gid = gid or 1000
    users = users or {}

    local group_line = table.concat({
        groupname,
        gid,
        table.concat(users, ",")
    }, ":")

    local file, e = vfs.open("/etc/group", "a")
    if not file then return nil, "cannot open /etc/group: " .. e end
    file:write(group_line .. "\n")
    file:close()

    group_load_group()
end

function group.getGroup(groupname)
    for index, value in ipairs(group._groups) do
        if value.name == groupname then
            return value
        end
    end
end

function group.getGroupByGID(gid)
    for _, value in ipairs(group._groups) do
        if value.gid == gid then
            return value
        end
    end
end

function group.init()
    user.updateUsers()
    local root_group_line = "root:0:root\n"
    if not vfs.exists("/etc/group") then
        local file = vfs.open("/etc/group", "w")
        file:write(root_group_line)
        file:close()
    end
    group_load_group()
    vfs.chmod("/etc/group", 644)
end
