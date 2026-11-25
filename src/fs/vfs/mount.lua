-- vfs/mount.lua - filesystems: finding one by address or label, mount,
-- the mount table and umount.

-- from the sources before this one
local vtab = vfsi.vtab
local openDescriptions = vfsi.openDescriptions
local removeEmptyNodes = vfsi.removeEmptyNodes
local createVNode = vfsi.createVNode
local vfs_root_hash = vfsi.vfs_root_hash
local getFsRelativePath = vfsi.getFsRelativePath
local findChild = vfsi.findChild
local ensureLoaded = vfsi.ensureLoaded
local isRootCaller = vfsi.isRootCaller
local mountInfo = vfsi.mountInfo

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
    if vfsi.metadataSaving then return false, "Filesystem metadata synchronization is in progress" end
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
