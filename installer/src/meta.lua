-- installer/src/meta.lua - the .meta files of the Nexus VFS
--
-- Each directory's .meta has one line per child (src/fs/vfs/meta.lua):
--   name:vtype:hash:mtime:btime:mode:refcount:uid:gid:link
-- vtype is VREG or VDIR, hash is FNV-1a of the name, times are seconds
-- since the Unix epoch and mode is written in octal digits (4755).
-- Also loaded by tools/nximg.lua on the build host; plain Lua only.

meta = {}

function meta.fnv1a(str)
    local hash = 2166136261
    for i = 1, #str do
        hash = (hash ~ str:byte(i)) & 0xFFFFFFFF
        hash = (hash * 16777619) % 4294967296
        hash = math.tointeger(hash) & 0xFFFFFFFF
    end
    return hash
end

-- One .meta line. mode is the permission bits as a number (493 for 0755).
---@param name string
---@param isDir boolean
---@param mode integer
---@param uid integer
---@param gid integer
---@param time integer
function meta.line(name, isDir, mode, uid, gid, time)
    return string.format("%s:%s:%d:%d:%d:%o:1:%d:%d:\n", name, isDir and "VDIR" or "VREG",
        meta.fnv1a(name), time, time, mode, uid, gid)
end

-- Collects attributes per directory and writes the .meta files.
-- add("/usr/bin/sudo.lua", false, 2541, 0, 0)
function meta.new()
    local dirs = {}
    local set = {}
    function set.add(path, isDir, mode, uid, gid)
        local dir, name = path:match("^(.*)/([^/]+)$")
        if dir == "" then dir = "/" end
        local entries = dirs[dir]
        if not entries then
            entries = { order = {} }
            dirs[dir] = entries
        end
        if not entries[name] then entries.order[#entries.order + 1] = name end
        entries[name] = { isDir = isDir, mode = mode, uid = uid or 0, gid = gid or 0 }
    end
    -- calls write(dirPath, text) for every directory, in path order
    function set.each(time, write)
        local paths = {}
        for dir in pairs(dirs) do paths[#paths + 1] = dir end
        table.sort(paths)
        for _, dir in ipairs(paths) do
            local entries, lines = dirs[dir], {}
            for _, name in ipairs(entries.order) do
                local e = entries[name]
                lines[#lines + 1] = meta.line(name, e.isDir, e.mode, e.uid, e.gid, time)
            end
            write(dir, table.concat(lines))
        end
    end
    return set
end
