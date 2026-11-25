-- vfs/path.lua - permissions (can), path resolution and lookup of vnodes,
-- and the path helpers (realPath, canonical, concat, ...).

-- from the sources before this one
local vtab = vfsi.vtab
local vfs_root_hash = vfsi.vfs_root_hash
local getFsRelativePath = vfsi.getFsRelativePath
local ensureLoaded = vfsi.ensureLoaded

local function isRootCaller()
    local proc = process.getCurrent()
    return proc == nil or proc.euid == 0
end

-- Plain description of a mounted filesystem; never the filesystem object.
---@param fs table
local function mountInfo(fs)
    local okL, label = pcall(fs.getLabel)
    local okR, ro = pcall(fs.isReadOnly)
    return {
        address  = fs.address,
        label    = okL and label or nil,
        readOnly = okR and ro or false,
    }
end

---@param vnode vnode
---@param proc table
---@param action fs_action
---@return boolean
local function checkPerms(vnode, proc, action)
    if proc.euid == 0 then return true end

    local perm_func
    if vnode.uid == (proc.euid or proc.uid) then
        if action == "r" then
            perm_func = permission.canOwnerRead
        elseif action == "w" then
            perm_func = permission.canOwnerWrite
        elseif action == "x" then
            perm_func = permission.canOwnerExec
        end
    elseif vnode.gid == (proc.egid or proc.gid) then
        if action == "r" then
            perm_func = permission.canGroupRead
        elseif action == "w" then
            perm_func = permission.canGroupWrite
        elseif action == "x" then
            perm_func = permission.canGroupExec
        end
    else
        if action == "r" then
            perm_func = permission.canOtherRead
        elseif action == "w" then
            perm_func = permission.canOtherWrite
        elseif action == "x" then
            perm_func = permission.canOtherExec
        end
    end

    if not perm_func then return false end
    return perm_func(vnode.mode)
end

---@param path string
---@param action fs_action
---@return boolean
function vfs.can(path, action)
    path = vfs.resolve(path)
    local proc = process.getCurrent() or { suid = 0, euid = 0, uid = 0 }

    if proc.euid == 0 then return true end

    local rootNode = vfsk.lookup("/")
    if not rootNode or not checkPerms(rootNode, proc, "x") then
        return false
    end

    local parts     = vfs.segments(path)
    local checkPath = "/"
    for i = 1, #parts - 1 do
        checkPath = vfs.concat(checkPath, parts[i])
        local node = vfsk.lookup(checkPath)
        if not node then return false end
        if not checkPerms(node, proc, "x") then return false end
    end

    local vnode = vfsk.lookup(path)
    if not vnode then return false end
    return checkPerms(vnode, proc, action)
end

---@param path string
---@return string
function vfs.resolve(path)
    if not path then return nil end
    if unicode.sub(path, 1, 1) == "/" then
        return vfs.canonical(path)
    else
        return vfs.canonical(vfs.concat(process.cwd(), path))
    end
end

---@return vnode
function vfsk.root()
    return vtab[vfs_root_hash]
end

---@param path string
---@return vnode|nil
---@return string|nil
---@return vnode|nil
function vfsk.lookup(path)
    local current = vtab[vfs_root_hash]
    if not current then return nil, nil, nil end
    if path == "/" then return current, nil, current end

    path = vfs.resolve(path)
    local norm_path = vfs.canonical(path)
    local parts = vfs.segments(norm_path)

    local mount_node = current
    local relative_parts = {}

    for i, name in ipairs(parts) do
        while current.type == "VLNK" and current.link do
            local link_path
            if type(current.link) == "string" then
                link_path = current.link
            else
                link_path = vfs.realPath(current.link)
            end

            local rest_parts = {}
            for j = i, #parts do table.insert(rest_parts, parts[j]) end
            local rest_path = table.concat(rest_parts, "/")

            local new_path
            if link_path:sub(1, 1) == "/" then
                new_path = vfs.canonical(vfs.concat(link_path, rest_path))
            else
                local base_path = vfs.realPath(current.parent) or "/"
                new_path = vfs.canonical(vfs.concat(base_path, link_path, rest_path))
            end
            return vfsk.lookup(new_path)
        end

        if current.loaded == false then ensureLoaded(current) end
        local name_hash = fnv1a_hash(name)
        local next_node = current.children[name_hash]
        if not next_node then
            for _, node in pairs(current.children) do
                if node.name == name then
                    next_node = node; break
                end
            end
            if not next_node and current.fs and current.fs.dynamic then
                local fs_rel    = getFsRelativePath(current)
                local check     = (fs_rel == "/" and "" or fs_rel) .. "/" .. name
                if current.fs.exists(check) then
                    -- a dynamic fs may expose symlinks (procfs: /proc/<pid>/fd/N)
                    local linkTarget = current.fs.readlink and current.fs.readlink(check)
                    local isDir = not linkTarget and current.fs.isDirectory(check)
                    next_node = {
                        name     = name,
                        hash     = name_hash,
                        type     = linkTarget and "VLNK" or (isDir and "VDIR" or "VREG"),
                        parent   = current,
                        children = {},
                        fs       = current.fs,
                        link     = linkTarget,
                        mtime    = 0,
                        btime    = 0,
                        refcount = 1,
                        mode     = linkTarget and 0777 or (isDir and 0555 or 0444),
                        uid      = 0,
                        gid      = 0,
                        size     = 0,
                    }
                end
            end
            if not next_node then return nil, nil, nil end
        end
        current = next_node

        if current.fs then
            mount_node = current
            relative_parts = {}
        else
            table.insert(relative_parts, name)
        end
    end

    local relative_path = #relative_parts > 0 and table.concat(relative_parts, "/") or nil
    return current, relative_path, mount_node
end

---@param vnode vnode|string|nil a vnode (kernel) or a path
---@return string|nil
function vfs.realPath(vnode)
    if type(vnode) == "string" then
        vnode = vfsk.lookup(vfs.resolve(vnode))
        -- lookup follows links inside the path; a path also resolves its last one
        local hops = 0
        while vnode and vnode.type == "VLNK" and vnode.link and hops < 16 do
            vnode = type(vnode.link) == "string" and vfsk.lookup(vnode.link) or vnode.link
            hops = hops + 1
        end
    end
    if type(vnode) ~= "table" then return nil end
    local parts     = {}
    local current   = vnode
    local max_depth = 100
    while current and max_depth > 0 do
        if current.parent == nil then
            table.insert(parts, 1, "")
            break
        else
            table.insert(parts, 1, current.name)
        end
        current   = current.parent
        max_depth = max_depth - 1
    end
    if max_depth == 0 then
        panic("not syncing", "possible cyclic vnode parent reference")
    end
    local path = table.concat(parts, "/")
    return path ~= "" and path or "/"
end

---@param path string
---@return string
function vfs.canonical(path)
    local is_absolute = path:sub(1, 1) == "/"
    local parts = vfs.segments(path)
    local stack = {}
    for _, part in ipairs(parts) do
        if part == "" or part == "." then
            -- skip
        elseif part == ".." then
            if #stack > 0 then
                table.remove(stack)
            elseif not is_absolute then
                table.insert(stack, "..")
            end
        else
            table.insert(stack, part)
        end
    end
    local normalized = table.concat(stack, "/")
    if is_absolute then normalized = "/" .. normalized end
    if normalized == "" then normalized = is_absolute and "/" or "." end
    return normalized
end

---@param path string
---@return table
function vfs.segments(path)
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        table.insert(parts, part)
    end
    return parts
end

---@param ... string
---@return string
function vfs.concat(...)
    local args  = { ... }
    local parts = {}
    for i = 1, #args do
        local current = args[i]
        if current and current ~= "" then
            if type(current) ~= "string" then current = tostring(current) end
            table.insert(parts, current)
        end
    end
    return vfs.canonical(table.concat(parts, "/"))
end

---@param path string
---@return string
function vfs.path(path)
    local parts = vfs.segments(path)
    if #parts <= 1 then
        return path:sub(1, 1) == "/" and "/" or ""
    end
    local result = table.concat(parts, "/", 1, #parts - 1) .. "/"
    if path:sub(1, 1) == "/" and result:sub(1, 1) ~= "/" then
        return "/" .. result
    end
    return result
end

---@param path string
---@return string
function vfs.name(path)
    local parts = vfs.segments(path)
    return parts[#parts] or "/"
end

-- for the sources after this one
vfsi.isRootCaller = isRootCaller
vfsi.mountInfo = mountInfo
