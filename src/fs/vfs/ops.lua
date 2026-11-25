-- vfs/ops.lua - operations on paths: links, queries (exists, size, list,
-- statfs), makeDirectory, remove, rename, touch, copy, open, chmod, chown.

-- from the sources before this one
local openDescriptions = vfsi.openDescriptions
local removeEmptyNodes = vfsi.removeEmptyNodes
local createVNode = vfsi.createVNode
local getFsRelativePath = vfsi.getFsRelativePath
local touch = vfsi.touch
local findChild = vfsi.findChild
local ensureLoaded = vfsi.ensureLoaded
local markDirty = vfsi.markDirty
local releaseDescription = vfsi.releaseDescription
local allocFd = vfsi.allocFd
local readRegularFile = vfsi.readRegularFile
local seekBufferedFile = vfsi.seekBufferedFile
local mountInfo = vfsi.mountInfo

---@param path string
---@return boolean
---@return string|nil
function vfs.isLink(path)
    local vnode = vfsk.lookup(path)
    if vnode and vnode.type == "VLNK" and vnode.link then
        if type(vnode.link) == "string" then return true, vnode.link end
        return true, vfs.realPath(vnode.link)
    end
    return false
end

---@param target string
---@param linkpath string
---@return boolean
---@return string|nil
function vfs.link(target, linkpath)
    if vfsk.lookup(linkpath) then return false, "File exists" end

    local targetNode = vfsk.lookup(target)
    if not targetNode then return false, "No such file or directory" end

    local parentPath = vfs.path(linkpath)
    local parentNode = vfsk.lookup(parentPath)
    if not parentNode then return false, "Parent directory does not exist" end
    if not (vfs.can(parentPath, "w") and vfs.can(parentPath, "x")) then
        return false, "Permission denied"
    end

    local name = vfs.name(linkpath)
    local hash = fnv1a_hash(name)
    parentNode.children[hash] = {
        name     = name,
        hash     = hash,
        type     = "VLNK",
        mtime    = getRealTime(),
        btime    = getRealTime(),
        mode     = 0777,
        children = {},
        refcount = 1,
        uid      = 0,
        gid      = 0,
        size     = 0,
        link     = targetNode,
        parent   = parentNode,
    }
    markDirty(parentNode)
    return true
end

---@param path string
---@return string|nil
---@return string|nil
function vfs.readlink(path)
    path = vfs.resolve(path)
    local vnode = vfsk.lookup(path)
    if not vnode then return nil, "No such file or directory" end
    if vnode.type ~= "VLNK" or not vnode.link then return nil, "Not a symbolic link" end
    if type(vnode.link) == "string" then return vnode.link end
    return vfs.realPath(vnode.link)
end

---@param path string a mount point
---@return table|nil mount info
---@return string|nil
function vfs.get(path)
    local vnode = vfsk.lookup(path)
    if vnode and vnode.fs then
        return mountInfo(vnode.fs), vfs.realPath(vnode)
    end
    return nil, "No such file system"
end

---@param path string
---@return boolean
function vfs.exists(path)
    path = vfs.resolve(path)
    return vfsk.lookup(path) ~= nil
end

---@param path string
---@return integer
function vfs.size(path)
    local vnode = vfsk.lookup(path)
    if vnode and vnode.fs then
        return vnode.fs.size(getFsRelativePath(vnode))
    end
    return 0
end

---@param path string
---@return boolean
function vfs.isDirectory(path)
    path = vfs.resolve(path)
    local vnode = vfsk.lookup(path)
    if not vnode then return false end
    if vnode.type == "VLNK" and vnode.link then
        if type(vnode.link) == "string" then
            local target = vfsk.lookup(vnode.link)
            return target ~= nil and target.type == "VDIR"
        end
        return vnode.link.type == "VDIR"
    end
    return vnode.type == "VDIR"
end

---@param path string
---@return integer
function vfs.lastModified(path)
    local vnode = vfsk.lookup(path)
    if vnode and vnode.fs then
        return vnode.fs.lastModified(getFsRelativePath(vnode))
    end
    return 0
end

---@param path string
---@return function|nil
---@return string|nil
function vfs.list(path)
    path = vfs.resolve(path)
    local vnode, rest, mp = vfsk.lookup(path)
    if not vnode or not mp then return nil, "No such file or directory" end

    if vnode.type == "VLNK" then
        if not vnode.link then error("Invalid link") end
        if type(vnode.link) == "string" then
            vnode = vfsk.lookup(vnode.link)
            if not vnode then error("Broken link") end
        else
            vnode = vnode.link
        end
    end

    if vnode.fs and vnode.fs.dynamic then
        local fs_path = getFsRelativePath(vnode)
        local entries = vnode.fs.list(fs_path)
        if entries and type(entries) == "table" then
            table.sort(entries)
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end
        return nil, "No such file or directory"
    end

    if vnode.loaded == false then ensureLoaded(vnode) end
    local list = {}
    for _, node in pairs(vnode.children) do
        table.insert(list, node.name)
    end
    table.sort(list)
    local i = 0
    return function()
        i = i + 1
        return list[i]
    end
end

-- Resolve a path whose final component must be a directory. lookup() follows
-- symlinks in intermediate components but returns a final symlink vnode, so
-- follow that last link explicitly before mutation.
local function followFinalLink(vnode)
    local hops = 0
    while vnode and vnode.type == "VLNK" and vnode.link and hops < 16 do
        local link = vnode.link
        if type(link) == "table" then
            local targetPath = vfs.realPath(link)
            vnode = targetPath and vfsk.lookup(targetPath) or nil
        else
            local target = link
            if target:sub(1, 1) ~= "/" then
                target = vfs.concat(vfs.realPath(vnode.parent) or "/", target)
            end
            vnode = vfsk.lookup(target)
        end
        hops = hops + 1
    end
    return vnode
end

-- Return mount metadata and capacity for a path without exposing the backing
-- filesystem proxy. Kept separate from mounts(): callers inspecting one path
-- should not enumerate and probe every mounted filesystem.
---@param path string
---@return table|nil
---@return string|nil
function vfs.statfs(path)
    if type(path) ~= "string" then return nil, "bad argument #1 (string expected)" end
    if path == "" then return nil, "empty path" end
    local resolved = vfs.resolve(path)
    local node = vfsk.lookup(resolved)
    if not node then return nil, "No such file or directory" end

    local originalParent = vfs.path(resolved)
    if not vfs.can(originalParent, "x") then return nil, "Permission denied" end

    node = followFinalLink(node)
    if not node then return nil, "No such file or directory" end
    if node.type == "VLNK" then return nil, "Too many levels of symbolic links" end

    local targetPath = vfs.realPath(node) or resolved
    if not vfs.can(vfs.path(targetPath), "x") then return nil, "Permission denied" end

    local fs = node.fs
    if not fs then return nil, "No such file system" end

    -- Descendants inherit their filesystem pointer. The mount root is the
    -- first ancestor whose parent belongs to another filesystem.
    local mount = node
    while mount.parent and not mount.mounted and mount.parent.fs == fs do
        mount = mount.parent
    end
    local mountPath = vfs.realPath(mount)

    local function counter(name)
        if type(fs[name]) ~= "function" then return nil end
        local ok, value = pcall(fs[name])
        if ok and type(value) == "number" and value >= 0 then return value end
        return nil
    end
    local info = mountInfo(fs)
    info.total = counter("spaceTotal")
    info.used = counter("spaceUsed")
    info.mountPath = mountPath
    return info
end

local function lookupDirectory(path)
    local vnode, relative, mount = vfsk.lookup(path)
    if vnode and vnode.type == "VLNK" then
        vnode = followFinalLink(vnode)
        if vnode then
            local _, resolvedRelative, resolvedMount = vfsk.lookup(vfs.realPath(vnode) or "/")
            relative, mount = resolvedRelative, resolvedMount
        end
    end
    if not vnode or vnode.type ~= "VDIR" then return nil end
    return vnode, relative, mount
end

---@param path string
---@return boolean
---@return string|nil
function vfs.makeDirectory(path)
    path = vfs.resolve(path)
    if vfs.name(path) == ".meta" then return false, "Reserved metadata name" end
    local parentPath = vfs.path(path)
    local parent_vnode, _, mp = lookupDirectory(parentPath)

    if vfs.exists(path) then
        return false, "File exists"
    end

    if not parent_vnode or not mp then
        return false, "No such file or directory"
    end
    local authPath = vfs.realPath(parent_vnode) or parentPath
    if not (vfs.can(authPath, "w") and vfs.can(authPath, "x")
        and vfs.can(parentPath, "x")) then
        return false, "Permission denied"
    end

    local parent_fs_path = getFsRelativePath(parent_vnode)
    local full_rest
    if parent_fs_path == "/" then
        full_rest = "/" .. vfs.name(path)
    else
        full_rest = parent_fs_path .. "/" .. vfs.name(path)
    end

    local s, e = mp.fs.makeDirectory(full_rest)
    if s then
        local node = createVNode(vfs.name(path), "VDIR", parent_vnode, mp.fs)
        if not mp.fs.dynamic then node.loaded = false end
        local proc = process.getCurrent()
        if proc then
            node.uid, node.gid = proc.euid or proc.uid, proc.egid or proc.gid
        end
        markDirty(parent_vnode)
        return true
    end
    return false, e
end

---@param path string
---@return boolean
---@return string|nil
function vfs.remove(path)
    path = vfs.resolve(path)
    if path == "/" then return false, "Operation not permitted" end
    if vfs.name(path) == ".meta" then return false, "Reserved metadata name" end
    local parentPath = vfs.path(path)
    local parent = lookupDirectory(parentPath)
    if parent and parent.loaded == false then ensureLoaded(parent) end
    -- Mutations operate on the directory entry itself, so resolve only the
    -- parent and fetch the final component directly.
    local target = parent and findChild(parent, vfs.name(path))
    if not parent then return false, "No such file or directory" end
    if not target then return false, "No such file or directory" end
    if target == vfsk.root() or target.mounted
        or (target.fs and target.parent and target.parent.fs ~= target.fs) then
        return false, "Operation not permitted"
    end
    if target.type == "VDIR" then
        if target.loaded == false then ensureLoaded(target) end
        if next(target.children) then return false, "Directory not empty" end
        -- Some filesystem backends remove directories recursively. Verify the
        -- physical directory is also empty so an incomplete/stale vnode cache
        -- can never turn this into a recursive delete. VFS metadata is stored
        -- in the reserved .meta file and does not count as a user child.
        if target.fs then
            local called, entries, listErr = pcall(target.fs.list, getFsRelativePath(target))
            if not called then return false, tostring(entries) end
            if type(entries) ~= "table" then return false, listErr or "Unable to list directory" end
            for _, name in pairs(entries) do
                if type(name) ~= "string" then return false, "Invalid directory listing" end
                if name:gsub("^/*", ""):gsub("/*$", "") ~= ".meta" then
                    return false, "Directory not empty"
                end
            end
        end
    end

    local authPath = vfs.realPath(parent) or parentPath
    if not vfs.can(authPath, "w") or not vfs.can(authPath, "x")
        or not vfs.can(parentPath, "x") then
        return false, "Permission denied"
    end
    local proc = process.getCurrent()
    if permission.canSticky(parent.mode) and proc and proc.euid ~= 0
        and proc.euid ~= parent.uid and proc.euid ~= target.uid then
        return false, "Permission denied"
    end

    -- Links live in the VFS metadata. Regular files and directories must be
    -- removed from their backing filesystem before discarding their vnode.
    if target.fs and target.type ~= "VLNK" then
        local called, ok, err = pcall(target.fs.remove, getFsRelativePath(target))
        if not called then return false, tostring(ok) end
        if not ok then return false, err or "Unable to remove entry" end
    end
    parent.children[target.hash] = nil
    removeEmptyNodes(parent)
    markDirty(parent)
    return true
end

---@param oldPath string
---@param newPath string
---@return boolean
---@return string|nil
function vfs.rename(oldPath, newPath)
    oldPath, newPath = vfs.resolve(oldPath), vfs.resolve(newPath)
    if oldPath == "/" or newPath == "/" then return false, "Operation not permitted" end
    if vfs.name(oldPath) == ".meta" or vfs.name(newPath) == ".meta" then
        return false, "Reserved metadata name"
    end

    local oldParentPath, newParentPath = vfs.path(oldPath), vfs.path(newPath)
    local oldParent = lookupDirectory(oldParentPath)
    local newParent = lookupDirectory(newParentPath)
    if oldParent and oldParent.loaded == false then ensureLoaded(oldParent) end
    if newParent and newParent.loaded == false then ensureLoaded(newParent) end
    if not oldParent or not newParent then return false, "No such file or directory" end
    local source = findChild(oldParent, vfs.name(oldPath))
    if not source then return false, "No such file or directory" end

    if source == vfsk.root() or source.mounted
        or (source.fs and source.parent and source.parent.fs ~= source.fs) then
        return false, "Operation not permitted"
    end
    local sameEntry = oldParent == newParent and source.name == vfs.name(newPath)
    local existingDestination = findChild(newParent, vfs.name(newPath))
    if existingDestination and not sameEntry then return false, "File exists" end

    if source.type == "VDIR" then
        local ancestor = newParent
        while ancestor do
            if ancestor == source then return false, "Cannot move a directory into itself" end
            ancestor = ancestor.parent
        end
        local function hasMountedDescendant(dir)
            for _, child in pairs(dir.children or {}) do
                if child.fs and child.parent and child.parent.fs ~= child.fs then return true end
                if child.type == "VDIR" and hasMountedDescendant(child) then return true end
            end
            return false
        end
        if hasMountedDescendant(source) then return false, "Operation not permitted" end
    end

    local oldAuthPath = vfs.realPath(oldParent) or oldParentPath
    local newAuthPath = vfs.realPath(newParent) or newParentPath
    if not vfs.can(oldAuthPath, "w") or not vfs.can(oldAuthPath, "x")
        or not vfs.can(newAuthPath, "w") or not vfs.can(newAuthPath, "x")
        or not vfs.can(oldParentPath, "x") or not vfs.can(newParentPath, "x") then
        return false, "Permission denied"
    end
    local proc = process.getCurrent()
    local function stickyDenied(parent)
        return permission.canSticky(parent.mode) and proc and proc.euid ~= 0
            and proc.euid ~= parent.uid and proc.euid ~= source.uid
    end
    if stickyDenied(oldParent) or stickyDenied(newParent) then return false, "Permission denied" end
    -- A same-entry rename is a successful no-op, including when the path was
    -- spelled with redundant separators or dot components. It still requires
    -- the same parent permissions as any other rename request.
    if sameEntry then return true end

    local sourceFs = source.type == "VLNK" and oldParent.fs or source.fs
    local destinationFs = newParent.fs
    if not sourceFs or sourceFs ~= destinationFs then
        return false, "Cross-device link"
    end
    if source.type ~= "VLNK" then
        if type(sourceFs.rename) ~= "function" then return false, "Operation not supported" end
        local called, ok, err = pcall(sourceFs.rename, getFsRelativePath(source),
            vfs.concat(getFsRelativePath(newParent), vfs.name(newPath)))
        if not called then return false, tostring(ok) end
        if not ok then return false, err or "Unable to rename entry" end
    end

    oldParent.children[source.hash] = nil
    source.name = vfs.name(newPath)
    source.hash = fnv1a_hash(source.name)
    source.parent = newParent
    newParent.children[source.hash] = source
    markDirty(oldParent)
    markDirty(newParent)
    return true
end

---@param path string
---@return boolean
---@return string|nil
function vfs.touch(path)
    path = vfs.resolve(path)
    if vfs.name(path) == ".meta" then return false, "Reserved metadata name" end

    local vnode = vfsk.lookup(path)
    if not vnode then
        local parent = lookupDirectory(vfs.path(path))
        if parent and parent.fs and (parent.fs.dynamic
            or (parent.fs.isReadOnly and parent.fs.isReadOnly())) then
            return false, "Read-only file system"
        end
        -- open("w") creates a missing file. Since absence was checked first,
        -- it cannot truncate an existing file here.
        local file, err = vfs.open(path, "w")
        if not file then return false, err end
        file:close()
        return true
    end

    vnode = followFinalLink(vnode)
    if not vnode then return false, "No such file or directory" end
    if vnode.type == "VLNK" then return false, "Too many levels of symbolic links" end
    if vnode.fs and (vnode.fs.dynamic or (vnode.fs.isReadOnly and vnode.fs.isReadOnly())) then
        return false, "Read-only file system"
    end
    local proc = process.getCurrent()
    local owner = proc and proc.euid == vnode.uid
    local authPath = vfs.realPath(vnode) or path
    local parentPath = vfs.path(authPath)
    if not vfs.can(parentPath, "x") or not vfs.can(vfs.path(path), "x") then
        return false, "Permission denied"
    end
    if not (not proc or proc.euid == 0 or owner or vfs.can(authPath, "w")) then
        return false, "Permission denied"
    end
    touch(vnode)
    markDirty(vnode.parent)
    return true
end

function vfs.copy(fromPath, toPath)
    -- TODO
end

---@param path string
---@param mode? fs_mode
---@return vfs_handle|nil
---@return string|nil
function vfs.open(path, mode)
    path = vfs.resolve(path)
    mode = mode or "r"
    local mode_table = { r = true, rb = true, w = true, wb = true, a = true, ab = true }
    assert(mode_table[mode],
        "bad argument #2 (r[b], w[b] or a[b] expected, got " .. mode .. ")")

    local vnode, rest, mp = vfsk.lookup(path)
    -- lookup() leaves a final symlink in place: open the file it points to
    do
        local hops = 0
        while vnode and vnode.type == "VLNK" and vnode.link and hops < 16 do
            local target = vnode.link
            if type(target) == "string" then
                if target:sub(1, 1) ~= "/" then
                    target = vfs.concat(vfs.realPath(vnode.parent) or "/", target)
                end
            else
                target = vfs.realPath(target)
            end
            vnode, rest, mp = vfsk.lookup(target)
            hops = hops + 1
        end
        if hops > 0 and not vnode then return nil, "No such file or directory" end -- dangling link
        if vnode and vnode.type == "VLNK" then return nil, "Too many levels of symbolic links" end
    end
    local created
    if not vnode then
        if vfs.name(path) == ".meta" then return nil, "Reserved metadata name" end
        local parentPath = vfs.path(path)
        local parent, _, parentMp = lookupDirectory(parentPath)
        if not (mode:find("[wa]") and parent and parentMp) then
            return nil, "No such file or directory"
        end
        -- creating an entry needs write and search permission on the directory
        local authPath = vfs.realPath(parent) or parentPath
        if not (vfs.can(authPath, "w") and vfs.can(authPath, "x")
            and vfs.can(parentPath, "x")) then
            return nil, "Permission denied"
        end
        vnode   = createVNode(vfs.name(path), "VREG", parent, parentMp.fs)
        mp      = parentMp
        created = parent
        local proc = process.getCurrent()
        if proc then
            vnode.uid, vnode.gid = proc.euid or proc.uid, proc.egid or proc.gid
        end
    elseif not vfs.can(vfs.realPath(vnode) or path, mode:find("r") and "r" or "w") then
        return nil, "Permission denied"
    end

    if not mp then return nil, "No mount point found for path" end

    local fs             = mp.fs
    if not fs then
        panic("not syncing", "corrupted filesystem")
    end
    local fs_path        = getFsRelativePath(vnode)
    local handle, reason = fs.open(fs_path, mode)
    if not handle then
        if created then created.children[vnode.hash] = nil end
        return nil, reason
    end
    if created then markDirty(created) end

    -- The open file description. fs and handle live only here and in these
    -- closures; the returned object must not expose the filesystem.
    local desc = { fs = fs, fd = handle, vnode = vnode, flag = mode, ref = 1 }
    openDescriptions[desc] = true
    local proc = process.getCurrent()
    local tbl  = proc and proc.fd
    local fdnum = tbl and allocFd(tbl, desc)

    local function isOpen()
        if tbl then return tbl[fdnum + 1] == desc end
        return desc.ref > 0
    end

    local function release()
        if not isOpen() then return end
        if tbl then tbl[fdnum + 1] = nil end
        releaseDescription(desc)
    end

    ---@class vfs_handle
    local file = {}

    -- the descriptor number in the owning process (nil in kernel context)
    function file:fd() return fdnum end

    function file:close()
        if not isOpen() then error("file is already closed") end
        release()
    end

    function file:read(n)
        if not isOpen() then return nil, "file is closed" end
        if (desc.readAhead or type(n) ~= "number") and vnode.type == "VREG" then
            return readRegularFile(desc, n)
        end
        return fs.read(handle, n)
    end

    -- Like Lua's file:lines(...): an iterator returning read(fmt) for each
    -- format ("l" by default) until the first one gives nil. The file stays
    -- open; a read error or a closed file raises an error.
    function file:lines(...)
        local formats = table.pack(...)
        if formats.n == 0 then formats = { "l", n = 1 } end
        return function()
            if not isOpen() then error("file is already closed", 2) end
            local values = {}
            for i = 1, formats.n do
                local value, err = file:read(formats[i])
                if value == nil then
                    if err then error(err, 2) end
                    return table.unpack(values, 1, i - 1)
                end
                values[i] = value
            end
            return table.unpack(values, 1, formats.n)
        end
    end

    function file:readAll()
        if not isOpen() then return nil, "file is closed" end
        if vnode.type == "VREG" then
            local data, err = readRegularFile(desc, "*a")
            if err then error("fs: error while reading: " .. err .. " (path=" .. path .. ")") end
            return data
        end
        local chunks = {}
        while true do
            local chunk, err = fs.read(handle, config.filesystem_read_bytes)
            if not chunk then
                if err then
                    error("fs: error while reading: " .. err ..
                        " (path=" .. path .. " handle=" .. tostring(handle) .. ")")
                end
                break
            end
            chunks[#chunks + 1] = chunk
        end
        return table.concat(chunks)
    end

    function file:seek(whence, offset)
        if not isOpen() then return nil, "file is closed" end
        if desc.readAhead then return seekBufferedFile(desc, whence, offset) end
        return fs.seek(handle, whence, offset)
    end

    function file:write(str)
        if not isOpen() then return nil, "file is closed" end
        if vnode.type == "VREG" then
            touch(vnode)
            markDirty(vnode.parent)
        end
        return fs.write(handle, str)
    end

    return setmetatable(file, {
        __metatable = "file",
        __gc = release,
        __close = release,
    }), nil
end

---@param path string
---@param mode integer
-- `mode` uses the Nexus notation: octal digits written as a decimal number
-- (755 = rwxr-xr-x, 4755 adds set-user-ID). Returns true on success.
function vfs.chmod(path, mode)
    path = vfs.resolve(path)
    if not mode then return nil, "Mode does not specified" end
    mode = math.tointeger(tonumber(mode))
    if not mode or mode < 0 or mode > 7777 or not tostring(mode):match("^[0-7]+$") then
        return nil, "Invalid mode"
    end

    local vnode = vfsk.lookup(path)
    if not vnode then return nil, "No such file or directory" end

    local proc      = process.getCurrent()
    local canModify = false
    if not proc then
        canModify = (process.getCurrentPID() == -1)
    else
        canModify = (proc.euid == 0) or (proc.euid == vnode.uid)
    end

    if not canModify then return nil, "Permission denied" end
    if vnode.fs and vnode.fs.readOnlyImage then return nil, "Read-only file system" end

    vnode.mode = mode
    markDirty(vnode.parent)
    return true
end

---@param path string
---@param uid integer
---@param gid integer
function vfs.chown(path, uid, gid)
    path = vfs.resolve(path)
    if not uid or not gid then return nil, "UID or GID does not specified" end

    local vnode = vfsk.lookup(path)
    if not vnode then return nil, "No such file or directory" end

    local proc = process.getCurrent()
    if proc and proc.euid ~= 0 then
        local ownGroup = gid == vnode.gid or gid == proc.egid or gid == proc.gid
        if proc.euid ~= vnode.uid or uid ~= vnode.uid or not ownGroup then
            return nil, "Operation not permitted"
        end
    end

    if vnode.fs and vnode.fs.readOnlyImage then return nil, "Read-only file system" end
    vnode.uid = uid
    vnode.gid = gid
    markDirty(vnode.parent)
end
