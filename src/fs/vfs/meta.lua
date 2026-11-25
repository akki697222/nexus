-- vfs/meta.lua - persistent metadata: the .meta file of each directory
-- (mode, owner, times, links), loading it and saving the dirty directories.

-- from the sources before this one
local getFsRelativePath = vfsi.getFsRelativePath
local vnodeTimes = vfsi.vnodeTimes
local ensureLoaded = vfsi.ensureLoaded

local function writeMeta(dirPath, children, fs)
    if fs == devfs then return true end -- device nodes live in memory only
    if fs.isReadOnly and fs.isReadOnly() then return true end

    local meta = {}
    for _, child in pairs(children) do
        local persisted = child
        if child.mounted then persisted = child.covered end
        if persisted then
            vnodeTimes(persisted)
            local linkPath = ""
            if persisted.type == "VLNK" and persisted.link then
                if type(persisted.link) == "string" then
                    linkPath = persisted.link
                else
                    linkPath = vfs.realPath(persisted.link) or ""
                end
            end
            meta[#meta + 1] = string.format("%s:%s:%d:%d:%d:%d:%d:%d:%d:%s\n",
                persisted.name,
                persisted.type,
                persisted.hash,
                math.floor(persisted.mtime),
                math.floor(persisted.btime),
                persisted.mode,
                persisted.refcount or 1,
                persisted.uid,
                persisted.gid,
                linkPath)
        end
    end

    local metaPath = (dirPath == "/" and "" or dirPath) .. "/.meta"
    local handle, open_err = fs.open(metaPath, "w")
    if not handle then return nil, open_err or "Unable to open metadata file" end
    local write_ok, wrote, write_err = pcall(fs.write, handle, table.concat(meta))
    local close_ok, closed, close_err = pcall(fs.close, handle)
    if not write_ok then return nil, wrote end
    if wrote == false or wrote == nil then
        return nil, write_err or "Unable to write metadata file"
    end
    -- OC filesystem close() returns no value on success; a raised error is
    -- the only portable failure signal for close.
    if not close_ok then return nil, closed end
    if closed == false or (closed == nil and close_err ~= nil) then
        return nil, close_err or "Unable to close metadata file"
    end
    return true
end

---@param parent vnode
function vfsi.loadDirMetadata(path, parent, fs)
    local metaPath = (path == "/" and "" or path) .. "/.meta"
    if not fs.exists(metaPath) then return end

    local handle = fs.open(metaPath, "r")
    if not handle then return end

    local chunks = {}
    repeat
        local data = fs.read(handle, config.filesystem_read_bytes)
        if data then chunks[#chunks + 1] = data end
    until not data
    fs.close(handle)
    local buffer = table.concat(chunks)

    for line in string.gmatch(buffer, "[^\r\n]+") do
        local name, vtype, hash, mtime, btime, mode, refcount, uid, gid, link =
            string.match(line, "^([^:]+):([^:]+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):?(.*)")

        if name then
            local name_hash = fnv1a_hash(name)
            local child     = parent.children[name_hash]

            if not child then
                if vtype == "VLNK" then
                    child = {
                        name     = name,
                        hash     = name_hash,
                        type     = vtype,
                        parent   = parent,
                        children = {},
                        fs       = fs,
                        link     = (link ~= "" and link or nil),
                        mtime    = tonumber(mtime) or 0,
                        btime    = tonumber(btime) or 0,
                        refcount = tonumber(refcount) or 0,
                        mode     = tonumber(mode) or 0,
                        uid      = tonumber(uid) or 0,
                        gid      = tonumber(gid) or 0,
                        size     = 0
                    }
                    parent.children[name_hash] = child
                end
            else
                child.mtime    = tonumber(mtime) or 0
                child.btime    = tonumber(btime) or 0
                child.mode     = tonumber(mode) or 0
                child.refcount = tonumber(refcount) or 0
                child.uid      = tonumber(uid) or 0
                child.gid      = tonumber(gid) or 0
                child.size     = 0
                if vtype == "VLNK" and link and link ~= "" then
                    child.link = link
                end
            end
        end
    end
end

-- Rewrites the .meta of every directory changed since the last flush.
-- `yield`, when given, is called between directories so the vfs_sync kernel
-- thread spreads a large flush over several ticks instead of stalling.
---@param yield? fun()
function vfs.saveMetadata(yield)
    if vfsi.metadataSaving then return nil, "Metadata synchronization is already in progress" end
    vfsi.metadataSaving = true
    local pending = vfsi.dirtyDirs
    vfsi.dirtyDirs = {}
    local firstError
    for dir in pairs(pending) do
        local attached = dir.parent == nil or dir.parent.children[dir.hash] == dir
        if attached and dir.fs then
            -- never truncate a .meta whose entries were not read yet
            local ok, result, reason = pcall(function()
                if dir.loaded == false then ensureLoaded(dir) end
                return writeMeta(getFsRelativePath(dir), dir.children, dir.fs)
            end)
            if not ok or not result then
                -- Preserve failed work so a later periodic sync or shutdown
                -- retry can attempt it again.
                vfsi.dirtyDirs[dir] = true
                firstError = firstError or (ok and reason or result)
            end
        end
        if yield then
            local yielded, reason = pcall(yield)
            if not yielded then firstError = firstError or tostring(reason) end
        end
    end
    vfs._dirty = next(vfsi.dirtyDirs) ~= nil
    vfsi.metadataSaving = false
    if firstError then return nil, tostring(firstError) end
    return true
end
