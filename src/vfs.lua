---@class vfs : openos_fs
vfs = {}
-- Kernel-only vnode access. A chunk-level local: other kernel sources see it,
-- but it is never part of the `vfs` table handed to userland and modules,
-- which must not obtain vnodes (their .fs is a raw filesystem proxy).
local vfsk = {}
---@type table<integer, vnode>
local vtab = {}
---@type table<string, vfs_descriptor>
local vhandles = {}
---@type table<table, boolean>
local openDescriptions = {}
---@type devfs
local devfs

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

local loadDirMetadata

-- Times are whole seconds since the Unix epoch (real time). Nodes found on
-- disk without a .meta entry take the backing file's modification time,
-- fetched on first use so that listing a directory stays cheap.
---@param v vnode
local function vnodeTimes(v)
    if v.mtime == nil then
        local t = 0
        if v.fs and v.fs.lastModified then
            local ok, ms = pcall(v.fs.lastModified, getFsRelativePath(v))
            if ok and type(ms) == "number" and ms > 0 then t = math.floor(ms / 1000) end
        end
        v.mtime = t
        if v.btime == nil then v.btime = t end
    end
    return v.mtime, v.btime
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
                local isDir = fs.isDirectory(vfs.concat(path, name))
                local node = createVNode(name, isDir and "VDIR" or "VREG", dir, fs)
                node.mtime, node.btime = nil, nil -- from the disk unless .meta says otherwise
                if isDir then node.loaded = false end
            end
        end
    end
    loadDirMetadata(path, dir, fs)
end

---@type table<vnode, boolean>
local dirtyDirs = {}
local metadataSaving = false

-- Records that `dir`'s .meta must be rewritten; flushed by vfs.saveMetadata().
---@param dir vnode|nil
local function markDirty(dir)
    if dir and dir.fs then
        dirtyDirs[dir] = true
        vfs._dirty = true
    end
end

---@return table fd table of the calling process (index = fd + 1)
local kfds = {}
local function fdTable()
    local proc = process.getCurrent()
    if proc then return proc.fd end
    if not kfds[1] then
        -- kernel context: the console descriptors set up by devfs.init
        kfds[1], kfds[2], kfds[3] = vhandles["0"], vhandles["1"], vhandles["2"]
    end
    return kfds
end

---@param fd any
---@return table|nil description
local function descriptor(fd)
    if math.type(fd) ~= "integer" or fd < 0 then return nil end
    return fdTable()[fd + 1]
end

-- Drops one reference to an open file description; the underlying handle is
-- closed with the last one. Descriptions without `ref` (the console) persist.
local function releaseDescription(d)
    if not d.ref then return end
    d.ref = d.ref - 1
    if d.ref <= 0 then
        openDescriptions[d] = nil
        pcall((d.fs or devfs).close, d.fd)
    end
end

-- Lowest free descriptor, as open(2) allocates.
local function allocFd(tbl, d, minimum)
    local i = (minimum or 0) + 1
    while tbl[i] ~= nil do i = i + 1 end
    tbl[i] = d
    return i - 1
end

-- Buffered input belongs to the open file description, so duplicated and
-- inherited descriptors see the same read position.
local function readRegularFile(d, format)
    local pending = d.readAhead or ""
    if type(format) == "number" then
        if format < 0 or format % 1 ~= 0 then return nil, "Invalid read count" end
        if format == 0 then return "" end
        if #pending == 0 then return d.fs.read(d.fd, format) end
        local result = pending:sub(1, format)
        d.readAhead = #result < #pending and pending:sub(#result + 1) or nil
        return result
    end

    format = format or "*l"
    local all = format == "*a" or format == "a"
    local keepNewline = format == "*L" or format == "L"
    if not all and not keepNewline and format ~= "*l" and format ~= "l" then
        return nil, "Unsupported file read format"
    end

    local chunks = {}
    local chunkSize = config.filesystem_read_bytes or 4096
    if not all then chunkSize = math.min(chunkSize, 4096) end
    while true do
        local newline = not all and pending:find("\n", 1, true)
        if newline then
            chunks[#chunks + 1] = pending:sub(1, keepNewline and newline or newline - 1)
            d.readAhead = newline < #pending and pending:sub(newline + 1) or nil
            return table.concat(chunks)
        end
        if #pending > 0 then chunks[#chunks + 1] = pending end
        d.readAhead = nil
        local chunk, err = d.fs.read(d.fd, chunkSize)
        if not chunk or chunk == "" then
            if err then return nil, err end
            if all or #chunks > 0 then return table.concat(chunks) end
            return nil
        end
        pending = chunk
    end
end

local function seekBufferedFile(d, whence, offset)
    if whence == "cur" or whence == nil then
        offset = (offset or 0) - #d.readAhead
    end
    local position, err = (d.fs or devfs).seek(d.fd, whence, offset)
    if position ~= nil and position ~= false then d.readAhead = nil end
    return position, err
end

---@param tbl table a process fd table
---@return table a copy sharing the open file descriptions (fork/exec semantics)
function vfsk.inheritFds(tbl, stdio)
    local out = {}
    if stdio == nil then
        for i, d in pairs(tbl) do
            if d.ref then d.ref = d.ref + 1 end
            out[i] = d
        end
        return out
    end
    if type(stdio) ~= "table" then return nil, "Invalid stdio descriptor mapping" end

    -- Resolve and validate the complete mapping before changing any reference
    -- count. Use raw iteration so user supplied metatables cannot run here.
    local resolved = {}
    local function validSource(d, destination)
        if not d or type(d.flag) ~= "string" then return false end
        return d.flag:find(destination == 0 and "r" or "[wa]") ~= nil
    end
    for destination, source in next, stdio do
        if math.type(destination) ~= "integer" or destination < 0 or destination > 2
            or math.type(source) ~= "integer" or source < 0 then
            return nil, "Invalid stdio descriptor mapping"
        end
        local d = rawget(tbl, source + 1)
        if not validSource(d, destination) then
            return nil, "Invalid stdio source descriptor"
        end
        resolved[destination + 1] = d
    end
    -- A partial redirection leaves the other standard streams unchanged when
    -- their corresponding descriptors exist in the source table.
    for destination = 0, 2 do
        local slot = destination + 1
        if resolved[slot] == nil then
            local d = rawget(tbl, slot)
            if d then
                if not validSource(d, destination) then
                    return nil, "Invalid stdio source descriptor"
                end
                resolved[slot] = d
            end
        end
    end
    for i, d in pairs(resolved) do
        if d.ref then d.ref = d.ref + 1 end
        out[i] = d
    end
    return out
end

-- Closes every descriptor of an exiting process.
---@param tbl table
function vfsk.closeAllFds(tbl)
    for i, d in pairs(tbl) do
        tbl[i] = nil
        releaseDescription(d)
    end
end

---@return table fd table for a process without a parent: the console
function vfsk.consoleFds()
    return { vhandles["0"], vhandles["1"], vhandles["2"] }
end

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

    -- ルートの実行権限確認
    local rootNode = vfsk.lookup("/")
    if not rootNode or not checkPerms(rootNode, proc, "x") then
        return false
    end

    -- 各親ディレクトリの実行権限確認
    local parts     = vfs.segments(path)
    local checkPath = "/"
    for i = 1, #parts - 1 do
        checkPath = vfs.concat(checkPath, parts[i])
        local node = vfsk.lookup(checkPath)
        if not node then return false end
        if not checkPerms(node, proc, "x") then return false end
    end

    -- ターゲット自身の権限確認
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
                    local isDir = current.fs.isDirectory(check)
                    next_node = {
                        name     = name,
                        hash     = name_hash,
                        type     = isDir and "VDIR" or "VREG",
                        parent   = current,
                        children = {},
                        fs       = current.fs,
                        link     = nil,
                        mtime    = 0,
                        btime    = 0,
                        refcount = 1,
                        mode     = isDir and 0555 or 0444,
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

---@param filter string label or address
---@return table|nil
---@return string|nil
local function findFilesystem(filter)
    if type(filter) ~= "string" or filter == "" then return nil, "Invalid filesystem identifier" end
    local candidates = {}
    for address in component.list("filesystem") do
        local ok, proxy = pcall(component.proxy, address)
        if ok and type(proxy) == "table" then
            local labelOk, label = pcall(proxy.getLabel)
            candidates[#candidates + 1] = {
                address = address,
                proxy = proxy,
                label = labelOk and label or nil,
            }
        end
    end
    for _, candidate in ipairs(candidates) do
        if candidate.address == filter then return candidate.proxy end
    end
    local labels = {}
    for _, candidate in ipairs(candidates) do
        if candidate.label == filter then labels[#labels + 1] = candidate end
    end
    if #labels == 1 then return labels[1].proxy end
    if #labels > 1 then return nil, "Ambiguous filesystem label" end
    local prefixes = {}
    for _, candidate in ipairs(candidates) do
        if candidate.address:sub(1, #filter) == filter then
            prefixes[#prefixes + 1] = candidate
        end
    end
    if #prefixes == 1 then return prefixes[1].proxy end
    if #prefixes > 1 then return nil, "Ambiguous filesystem address prefix" end
    return nil, "No such filesystem"
end

local mountPoints

---@param filter string label or address
---@return table|nil mount info
---@return string|nil
function vfs.proxy(filter)
    if type(filter) ~= "string" then return nil, "bad argument #1 (string expected)" end
    local fs, e = findFilesystem(filter)
    if not fs then return nil, e end
    return mountInfo(fs)
end

---@param fs table|string filesystem object (kernel), mount info, label or address
---@param path string
---@return boolean
---@return string|nil
function vfs.mount(fs, path)
    if not isRootCaller() then return false, "Permission denied" end
    if type(fs) == "table" and type(fs.open) ~= "function" then 
        fs = fs.address -- mount info
    end
    if type(fs) == "string" then
        local e
        fs, e = findFilesystem(fs)
        if not fs then return false, e end
    end
    if type(fs) ~= "table" then
        return false, "bad argument #1 (filesystem, label or address expected)"
    end
    if type(path) ~= "string" or path == "" then return false, "Invalid mount path" end
    path = vfs.resolve(path)

    local address = fs.address
    for _, mounted in ipairs(mountPoints()) do
        if mounted.fs == fs or (address and mounted.fs.address == address) then
            return false, "Filesystem is already mounted"
        end
    end

    local root = vfsk.root()
    local parent, covered
    if path == "/" then
        if root then return false, "Already mounted" end
    else
        parent = vfsk.lookup(vfs.path(path))
        if not parent or parent.type ~= "VDIR" then
            return false, "Mount parent is not an existing directory"
        end
        if parent.loaded == false then ensureLoaded(parent) end
        covered = findChild(parent, vfs.name(path))
        if covered then
            if covered.type ~= "VDIR" then return false, "Mount target is not a directory" end
            if covered.mounted then return false, "Already mounted" end
            if covered.loaded == false then ensureLoaded(covered) end
            if next(covered.children) then return false, "Mount target is not empty" end
            if covered.fs and covered.fs.dynamic then
                local ok, entries = pcall(covered.fs.list, getFsRelativePath(covered))
                if not ok or type(entries) ~= "table" then return false, "Unable to inspect mount target" end
                for _, name in ipairs(entries) do
                    if name:gsub("^/*", ""):gsub("/*$", "") ~= ".meta" then
                        return false, "Mount target is not empty"
                    end
                end
            end
        end
    end

    local vnode = createVNode(vfs.name(path), "VDIR", parent, fs)
    vnode.mounted = true
    vnode.covered = covered
    if path == "/" then vtab[vfs_root_hash] = vnode end
    if not fs.dynamic then vnode.loaded = false end
    return true
end

---@return {fs: table, path: string}[]
mountPoints = function()
    local function build_path(node)
        local names = {}
        while node and node.parent do
            table.insert(names, 1, node.name)
            node = node.parent
        end
        return "/" .. table.concat(names, "/")
    end
    local mounts = {}
    local function collect_mounts(node)
        if node.mounted and node.fs then
            table.insert(mounts, { fs = node.fs, path = build_path(node) })
        end
        if node.children then
            for _, child in pairs(node.children) do
                if child.type == "VDIR" then collect_mounts(child) end
            end
        end
    end
    local root = vtab[vfs_root_hash]
    if root then collect_mounts(root) end
    return mounts
end

---@return function iterator yielding mount info, path
function vfs.mounts()
    local mounts = mountPoints()
    local i = 0
    return function()
        i = i + 1
        local m = mounts[i]
        if m then return mountInfo(m.fs), m.path end
    end
end

---@param target string mount path or (abbreviated) address
---@return boolean
function vfs.umount(target)
    if not isRootCaller() then return false, "Permission denied" end
    if type(target) ~= "string" or target == "" then return false, "Invalid mount target" end
    local mounts = mountPoints()
    local pathTarget = vfs.resolve(target)
    local matches = {}
    for _, mounted in ipairs(mounts) do
        if mounted.path == pathTarget then matches[#matches + 1] = mounted end
    end
    if #matches == 0 then
        for _, mounted in ipairs(mounts) do
            local address = mounted.fs.address
            if address == target then matches[#matches + 1] = mounted end
        end
        if #matches == 0 then
            for _, mounted in ipairs(mounts) do
                local okLabel, label = pcall(mounted.fs.getLabel)
                if okLabel and label == target then matches[#matches + 1] = mounted end
            end
        end
        if #matches == 0 then
            for _, mounted in ipairs(mounts) do
                local address = mounted.fs.address
                if address and address:sub(1, #target) == target then
                    matches[#matches + 1] = mounted
                end
            end
        end
    end
    if #matches == 0 then return false, "No such mount" end
    if #matches > 1 then return false, "Ambiguous mount target" end

    local mounted = matches[1]
    if mounted.path == "/" then return false, "Cannot unmount root filesystem" end
    local rootNode = vfsk.lookup(mounted.path)
    if not rootNode or not rootNode.mounted then return false, "Mount is no longer attached" end
    for _, childMount in ipairs(mounts) do
        if childMount ~= mounted and childMount.path:sub(1, #mounted.path + 1) == mounted.path .. "/" then
            return false, "Filesystem has a nested mount"
        end
    end

    local function withinMount(node)
        while node do
            if node == rootNode then return true end
            node = node.parent
        end
        return false
    end
    local function busy()
        for description in pairs(openDescriptions) do
            if description.fs == mounted.fs
                or (description.vnode and withinMount(description.vnode)) then
                return true
            end
        end
        local current = process.getCurrent()
        if current and current.cwd and withinMount(current.cwd) then return true end
        if type(process.list) == "function" and type(process.get) == "function" then
            local ok, processes = pcall(process.list)
            if ok and type(processes) == "table" then
                for _, entry in ipairs(processes) do
                    local got, proc = pcall(process.get, entry.pid)
                    if got and proc then
                        if proc.cwd and withinMount(proc.cwd) then return true end
                        for _, description in pairs(proc.fd or {}) do
                            if description and (description.fs == mounted.fs
                                or (description.vnode and withinMount(description.vnode))) then
                                return true
                            end
                        end
                    end
                end
            end
        end
        return false
    end
    if busy() then return false, "Filesystem is busy" end
    if metadataSaving then return false, "Filesystem metadata synchronization is in progress" end
    if vfs._dirty and type(vfs.saveMetadata) == "function" then
        local ok, err = vfs.saveMetadata()
        if not ok then return false, err or "Unable to flush filesystem metadata" end
    end

    local parent = rootNode.parent
    if not parent then return false, "Cannot unmount root filesystem" end
    local covered = rootNode.covered
    parent.children[rootNode.hash] = covered
    rootNode.mounted = false
    rootNode.covered = nil
    rootNode.fs = nil
    if covered then
        covered.parent = parent
    else
        removeEmptyNodes(parent)
    end
    return true
end

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
    -- FIX: getFsRelativePath でFS相対パスを使う (旧: rest変数 = VFS相対パスで不正確)
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
    -- FIX: getFsRelativePath でFS相対パスを使う
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
    vnode.mtime = getRealTime()
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
            vnode.mtime = getRealTime()
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

local function writeMeta(dirPath, children, fs)
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
function loadDirMetadata(path, parent, fs)
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
    if metadataSaving then return nil, "Metadata synchronization is already in progress" end
    metadataSaving = true
    local pending = dirtyDirs
    dirtyDirs = {}
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
                dirtyDirs[dir] = true
                firstError = firstError or (ok and reason or result)
            end
        end
        if yield then
            local yielded, reason = pcall(yield)
            if not yielded then firstError = firstError or tostring(reason) end
        end
    end
    vfs._dirty = next(dirtyDirs) ~= nil
    metadataSaving = false
    if firstError then return nil, tostring(firstError) end
    return true
end

-- Anonymous pipes use ordinary open-file descriptions so dup, exec and
-- process exit all share the same endpoint lifetime rules as regular files.
local PIPE_CAPACITY = 8192
local pipeHandles = {}
local nextPipeHandle = 1
local pipeFs = {}

local function pipePop(pipe, count)
    local amount = math.min(count, #pipe.buffer)
    if amount <= 0 then return "" end
    local result = pipe.buffer:sub(1, amount)
    pipe.buffer = pipe.buffer:sub(amount + 1)
    process.wakeIO(pipe.writers)
    return result
end

function pipeFs.read(handle, format)
    local endpoint = pipeHandles[tostring(handle)]
    if not endpoint or endpoint.side ~= "read" then return nil, "Bad file descriptor" end
    local pipe = endpoint.pipe
    local mode, count
    if format == nil then
        mode = "line"
    elseif type(format) == "number" then
        if math.type(format) ~= "integer" or format < 0 then return nil, "Invalid read count" end
        if format == 0 then return "" end
        mode, count = "count", format
    elseif type(format) == "string" then
        if format == "l" or format == "*l" then mode = "line"
        elseif format == "L" or format == "*L" then mode = "line_keep"
        elseif format == "a" or format == "*a" then mode = "all"
        else return nil, "Unsupported pipe read format" end
    else
        return nil, "Invalid read format"
    end

    if mode == "count" then
        while #pipe.buffer == 0 do
            if pipe.writersOpen == 0 then return nil end
            process.blockIO(pipe.readers)
        end
        return pipePop(pipe, count)
    end

    local chunks = {}
    while true do
        if #pipe.buffer > 0 then
            if mode == "all" then
                chunks[#chunks + 1] = pipePop(pipe, #pipe.buffer)
            else
                local newline = pipe.buffer:find("\n", 1, true)
                if newline then
                    local take = newline - (mode == "line" and 1 or 0)
                    if take > 0 then chunks[#chunks + 1] = pipePop(pipe, take) end
                    if mode == "line" then pipePop(pipe, 1) end
                    return table.concat(chunks)
                end
                chunks[#chunks + 1] = pipePop(pipe, #pipe.buffer)
            end
        elseif pipe.writersOpen == 0 then
            if mode == "all" then return table.concat(chunks) end
            if #chunks > 0 then return table.concat(chunks) end
            return nil
        else
            process.blockIO(pipe.readers)
        end
        if mode == "all" and pipe.writersOpen == 0 and #pipe.buffer == 0 then
            return table.concat(chunks)
        end
    end
end

function pipeFs.write(handle, value)
    local endpoint = pipeHandles[tostring(handle)]
    if not endpoint or endpoint.side ~= "write" then return nil, "Bad file descriptor" end
    if type(value) ~= "string" then return nil, "Invalid write data" end
    local pipe = endpoint.pipe
    local written = 0
    while written < #value do
        if pipe.readersOpen == 0 then
            if written > 0 then return written, "Broken pipe" end
            return nil, "Broken pipe"
        end
        local available = PIPE_CAPACITY - #pipe.buffer
        if available <= 0 then
            process.blockIO(pipe.writers)
        else
            local amount = math.min(available, #value - written)
            pipe.buffer = pipe.buffer .. value:sub(written + 1, written + amount)
            written = written + amount
            process.wakeIO(pipe.readers)
        end
    end
    return written
end

function pipeFs.seek()
    return nil, "Illegal seek"
end

function pipeFs.close(handle)
    local key = tostring(handle)
    local endpoint = pipeHandles[key]
    if not endpoint then return end
    pipeHandles[key] = nil
    local pipe = endpoint.pipe
    if endpoint.side == "read" then
        pipe.readersOpen = pipe.readersOpen - 1
        process.wakeIO(pipe.writers)
    else
        pipe.writersOpen = pipe.writersOpen - 1
        process.wakeIO(pipe.readers)
    end
end

---@return integer|nil read_fd
---@return integer|nil write_fd
---@return string|nil error
function vfs.pipe()
    local tbl = fdTable()
    local pipe = {
        buffer = "",
        readers = {},
        writers = {},
        readersOpen = 1,
        writersOpen = 1,
    }
    local readHandle, writeHandle = nextPipeHandle, nextPipeHandle + 1
    nextPipeHandle = nextPipeHandle + 2
    pipeHandles[tostring(readHandle)] = { pipe = pipe, side = "read" }
    pipeHandles[tostring(writeHandle)] = { pipe = pipe, side = "write" }
    -- Leave closed standard streams closed until explicitly redirected.
    local readFd = allocFd(tbl, { fs = pipeFs, fd = readHandle, flag = "r", ref = 1 }, 3)
    local writeFd = allocFd(tbl, { fs = pipeFs, fd = writeHandle, flag = "w", ref = 1 }, 3)
    return readFd, writeFd
end

---@param fd integer
---@return boolean
function vfs.isatty(fd)
    local d = descriptor(fd)
    return d ~= nil and (d == vhandles["0"] or d == vhandles["1"] or d == vhandles["2"])
end

---@param fd integer
---@param value any
function vfs.write(fd, value)
    local d = descriptor(fd)
    if not d or not (d.flag:find("w") or d.flag:find("a")) then return nil, "Bad file descriptor" end
    if d.vnode and d.vnode.type == "VREG" then
        d.vnode.mtime = getRealTime()
        markDirty(d.vnode.parent)
    end
    return (d.fs or devfs).write(d.fd, value)
end

---@param fd integer
function vfs.read(fd, ...)
    local d = descriptor(fd)
    if not d or not d.flag:find("r") then return nil, "Bad file descriptor" end
    local format = ...
    if (d.readAhead or type(format) ~= "number") and d.vnode and d.vnode.type == "VREG" then
        return readRegularFile(d, format)
    end
    return (d.fs or devfs).read(d.fd, ...)
end

---@param fd integer
function vfs.seek(fd, whence, offset)
    local d = descriptor(fd)
    if not d then return nil, "Bad file descriptor" end
    if d.readAhead then return seekBufferedFile(d, whence, offset) end
    return (d.fs or devfs).seek(d.fd, whence, offset)
end

---@param fd integer
function vfs.close(fd)
    local d = descriptor(fd)
    if not d then return nil, "Bad file descriptor" end
    fdTable()[fd + 1] = nil
    releaseDescription(d)
    return true
end

---@param fd integer
---@param minimum? integer lowest descriptor to allocate
---@return integer|nil new descriptor
---@return string|nil
function vfs.dup(fd, minimum)
    local d = descriptor(fd)
    if not d then return nil, "Bad file descriptor" end
    if minimum ~= nil and (math.type(minimum) ~= "integer" or minimum < 0) then
        return nil, "Invalid minimum descriptor"
    end
    if d.ref then d.ref = d.ref + 1 end
    return allocFd(fdTable(), d, minimum)
end

---@param fd integer
---@param newfd integer
---@return integer|nil
---@return string|nil
function vfs.dup2(fd, newfd)
    local d = descriptor(fd)
    if not d or math.type(newfd) ~= "integer" or newfd < 0 then return nil, "Bad file descriptor" end
    if fd == newfd then return newfd end
    local tbl = fdTable()
    local old = tbl[newfd + 1]
    if d.ref then d.ref = d.ref + 1 end
    tbl[newfd + 1] = d
    if old then releaseDescription(old) end
    return newfd
end

---@param parentPath string
---@param name string
---@param vtype vtype
---@param fs? oc_component_fs
---@param perm? integer
---@return vnode|nil
---@return string|nil
function vfsk.createVNode(parentPath, name, vtype, fs, perm)
    if vfsk.lookup(vfs.concat(parentPath, name)) then
        return nil, "VNode in the specified path already exists"
    end
    local parent = vfsk.lookup(parentPath)
    if not parent then
        return nil, "Parent VNode does not exist"
    end
    return createVNode(name, vtype, parent, fs, perm)
end

-- Public stat: a detached copy, never the vnode itself.
---@param path string
---@return table|nil
---@return string|nil
function vfs.attributes(path)
    path = vfs.resolve(path)
    local v = vfsk.lookup(path)
    if not v then return nil, "No such file or directory" end
    local link
    if v.type == "VLNK" and v.link then
        link = type(v.link) == "string" and v.link or vfs.realPath(v.link)
    end
    vnodeTimes(v)
    return {
        name  = v.name,
        type  = v.type,
        mode  = v.mode,
        uid   = v.uid,
        gid   = v.gid,
        size  = v.type == "VREG" and vfs.size(path) or (v.size or 0),
        mtime = v.mtime,
        btime = v.btime,
        link  = link,
    }
end

---@param filename string
---@param mode? string
---@param env? table
loadfile = function(filename, mode, env)
    local file, err = vfs.open(filename, "r")
    if not file then return nil, err end

    local chunks = ""

    while true do
        local data, reason = file:read(config.filesystem_read_bytes)
        
        if not data then
            if reason then
                file:close()
                return nil, reason
            end
            break
        end
        
        chunks = chunks .. data
    end
    file:close()

    local chunk, load_err = load(chunks, "=" .. filename, mode or "bt", env or (util and util.createEnv() or _G))
    if not chunk then return nil, load_err end
    return chunk
end
