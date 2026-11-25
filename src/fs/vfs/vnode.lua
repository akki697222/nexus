-- vfs/vnode.lua - the vnode tree: the vfs, vfsk and vfsi tables, vnode
-- creation and lookup of children, lazy loading of directories and the dirty
-- set for metadata. First of the fs/vfs sources (see properties.lua).

---@class vfs : openos_fs
vfs = {}
-- Kernel-only vnode access, shared with other kernel sources through
-- prelude.lua; never part of the `vfs` table handed to userland and modules,
-- which must not obtain vnodes (their .fs is a raw filesystem proxy).
vfsk = {}
-- Internals the fs/vfs sources share (state and helpers); kernel-private.
vfsi = {}
---@type table<integer, vnode>
local vtab = {}
---@type table<string, vfs_descriptor>
vhandles = {}
---@type table<table, boolean>
local openDescriptions = {}

---@class vnode
---@field name string
---@field type vtype
---@field hash integer
---@field mtime number
---@field btime number
---@field size integer
---@field mode integer
---@field children table<integer, vnode>
---@field refcount integer
---@field parent vnode|nil
---@field fs oc_component_fs|nil
---@field mounted boolean?
---@field covered vnode|nil
---@field link vnode|string|nil
---@field uid integer
---@field gid integer

---@class vfs_descriptor
---@field fs oc_component_fs?
---@field vnode vnode?
---@field flag fs_mode
---@field fd integer

---@alias vtype
---| '"VREG"'  # Regular File
---| '"VDIR"'  # Directory
---| '"VCHR"'  # Character Device (like terminal)
---| '"VBLK"'  # Block Device (like filesystem)
---| '"VFIFO"' # FIFO (named pipe)
---| '"VSOCK"' # Socket
---| '"VLNK"'  # Symlink

---@alias fs_mode
---| '"r"'
---| '"rb"'
---| '"w"'
---| '"wb"'
---| '"a"'
---| '"ab"'

---@alias fs_action
---| '"r"'
---| '"w"'
---| '"x"'

local function removeEmptyNodes(node)
    while node and node.parent
        and not node.mounted
        and not node.fs
        and (not node.children or not next(node.children))
        and (not node.links or not next(node.links)) do
        node.parent.children[node.name] = nil
        node = node.parent
    end
end

---@param name string
---@param vtype vtype
---@param parent vnode|nil
---@param fs? oc_component_fs
---@param perm? integer
---@return vnode
local function createVNode(name, vtype, parent, fs, perm)
    local hash = fnv1a_hash(name)
    ---@type vnode
    local node = {
        name     = name,
        hash     = hash,
        type     = vtype,
        parent   = parent,
        children = {},
        fs       = fs,
        link     = nil,
        mtime    = getRealTime(),
        btime    = getRealTime(),
        refcount = 1,
        mode     = perm or (vtype == "VDIR" and 0755 or 0644),
        uid      = 0,
        gid      = 0,
        size     = 0
    }
    if parent then
        parent.children[hash] = node
    end
    return node
end

local vfs_root_hash = fnv1a_hash("/")

---@param node vnode
---@return string
local function getFsRelativePath(node)
    if not node then return "/" end
    local parts   = {}
    local current = node
    while current.parent and not current.mounted and current.parent.fs == current.fs do
        table.insert(parts, 1, current.name)
        current = current.parent
    end
    if #parts == 0 then return "/" end
    return "/" .. table.concat(parts, "/")
end


-- Times are whole seconds since the Unix epoch (real time). Nodes found on
-- disk without a .meta entry take the backing file's modification time,
-- fetched on first use so that listing a directory stays cheap.
---@param v vnode
local function vnodeTimes(v)
    if v.mtime == nil or v.btime == nil then
        local t = 0
        if v.fs and v.fs.lastModified then
            local ok, ms = pcall(v.fs.lastModified, getFsRelativePath(v))
            if ok and type(ms) == "number" and ms > 0 then t = math.floor(ms / 1000) end
        end
        if v.mtime == nil then v.mtime = t end
        if v.btime == nil then v.btime = t end
    end
    return v.mtime, v.btime
end

-- A lazily loaded node keeps its times nil until first use; resolve them
-- from the disk before a write replaces mtime, or btime would stay nil.
local function touch(v)
    vnodeTimes(v)
    v.mtime = getRealTime()
end

---@param dir vnode
---@param name string
---@return vnode|nil
local function findChild(dir, name)
    local node = dir.children[fnv1a_hash(name)]
    if node and node.name == name then return node end
    for _, n in pairs(dir.children) do
        if n.name == name then return n end
    end
end

-- Populates `dir` from its backing filesystem on first access, one level at
-- a time, instead of scanning the whole disk into memory at mount time.
---@param dir vnode
local function ensureLoaded(dir)
    if dir.loaded ~= false then return end
    dir.loaded = true
    local fs = dir.fs
    local path = getFsRelativePath(dir)
    local entries = fs.list(path)
    if entries then
        for _, name in ipairs(entries) do
            name = name:gsub("^/*", ""):gsub("/*$", "")
            if name ~= "" and name ~= ".meta" and not findChild(dir, name) then
                local linkTarget = fs.readlink and fs.readlink(vfs.concat(path, name))
                local isDir = not linkTarget and fs.isDirectory(vfs.concat(path, name))
                local node = createVNode(name, linkTarget and "VLNK" or (isDir and "VDIR" or "VREG"), dir, fs)
                node.mtime, node.btime = nil, nil -- from the disk unless .meta says otherwise
                if linkTarget then node.link = linkTarget; node.mode = 0777 end
                if isDir then node.loaded = false end
            end
        end
    end
    vfsi.loadDirMetadata(path, dir, fs)
end

---@type table<vnode, boolean>
-- directories whose metadata changed, and whether saveMetadata is running
vfsi.dirtyDirs = {}
vfsi.metadataSaving = false

-- Records that `dir`'s .meta must be rewritten; flushed by vfs.saveMetadata().
---@param dir vnode|nil
local function markDirty(dir)
    if dir and dir.fs then
        vfsi.dirtyDirs[dir] = true
        vfs._dirty = true
    end
end

-- for the sources after this one
vfsi.openDescriptions = openDescriptions
vfsi.vtab = vtab
vfsi.vfs_root_hash = vfs_root_hash
vfsi.getFsRelativePath = getFsRelativePath
vfsi.ensureLoaded = ensureLoaded
vfsi.removeEmptyNodes = removeEmptyNodes
vfsi.createVNode = createVNode
vfsi.findChild = findChild
vfsi.touch = touch
vfsi.markDirty = markDirty
vfsi.vnodeTimes = vnodeTimes
