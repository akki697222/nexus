---@class vfs : openos_fs
vfs = {}
---@type table<integer, vnode>
local vtab = setmetatable({}, { __mode = "v" })
---@type table<string, vfs_descriptor>
local vhandles = {}
---@type devfs
local devfs
local vfs_root = nil

---@class vnode
---@field name string
---@field type vtype
---@field hash integer
---@field mtime number
---@field btime number
---@field mode integer
---@field children table<integer, vnode>
---@field refcount integer
---@field parent vnode|nil
---@field fs oc_component_fs|nil
---@field link vnode|string|nil
---@field uid integer
---@field gid integer

---@class vfs_descriptor
---@field fs oc_component_fs?
---@field vnode vnode?
---@field flag fs_mode
---@field fd integer

---@alias vtype
---| '"VREG"'  # 通常ファイル (regular file)
---| '"VDIR"'  # ディレクトリ (directory)
---| '"VCHR"'  # キャラクターデバイス (character device)
---| '"VBLK"'  # ブロックデバイス (block device)
---| '"VFIFO"' # FIFO (名前付きパイプ)
---| '"VSOCK"' # ソケット (socket)
---| '"VLNK"'  # シンボリックリンク (symbolic link)
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
        -- 弱参照テーブルでchildrenを管理 → GCが未参照vnodeを自動回収
        children = setmetatable({}, { __mode = "v" }),
        fs       = fs,
        link     = nil,
        mtime    = os.time(),
        btime    = os.time(),
        refcount = 1,
        mode     = perm or (vtype == "VDIR" and 0755 or 0644),
        uid      = 0,
        gid      = 0,
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
    while current.parent and current.parent.fs == current.fs do
        table.insert(parts, 1, current.name)
        current = current.parent
    end
    if #parts == 0 then return "/" end
    return "/" .. table.concat(parts, "/")
end

---@param vnode vnode
---@param proc table
---@param action fs_action
---@return boolean
local function checkPerms(vnode, proc, action)
    if proc.euid == 0 then return true end

    local perm_func
    if vnode.uid == proc.uid then
        if action == "r" then
            perm_func = permission.canOwnerRead
        elseif action == "w" then
            perm_func = permission.canOwnerWrite
        elseif action == "x" then
            perm_func = permission.canOwnerExec
        end
    elseif vnode.gid == proc.gid then
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

    local rootNode = vfs.attributes("/")
    if not rootNode or not checkPerms(rootNode, proc, "x") then
        return false
    end

    local parts     = vfs.segments(path)
    local checkPath = "/"
    for i = 1, #parts - 1 do
        checkPath = vfs.concat(checkPath, parts[i])
        local node = vfs.attributes(checkPath)
        if not node then return false end
        if not checkPerms(node, proc, "x") then return false end
    end

    local vnode = vfs.attributes(path)
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
function vfs.root()
    return vfs_root
end

-- .metaファイルからディレクトリのメタデータを読み込む
-- attributes()内でディレクトリvnode生成時に呼ばれる
local function loadDirMetadata(path, parent, fs)
    local metaPath = (path == "/" and "" or path) .. "/.meta"
    if not fs.exists(metaPath) then return end

    local handle = fs.open(metaPath, "r")
    if not handle then return end

    local buffer = ""
    repeat
        local data = fs.read(handle, 1024)
        if data then buffer = buffer .. data end
    until not data
    fs.close(handle)

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
                        children = setmetatable({}, { __mode = "v" }),
                        fs       = fs,
                        link     = (link ~= "" and link or nil),
                        mtime    = tonumber(mtime),
                        btime    = tonumber(btime),
                        refcount = tonumber(refcount),
                        mode     = tonumber(mode),
                        uid      = tonumber(uid),
                        gid      = tonumber(gid),
                    }
                    parent.children[name_hash] = child
                end
            else
                child.mtime    = tonumber(mtime)
                child.btime    = tonumber(btime)
                child.mode     = tonumber(mode)
                child.refcount = tonumber(refcount)
                child.uid      = tonumber(uid)
                child.gid      = tonumber(gid)
                if vtype == "VLNK" and link and link ~= "" then
                    child.link = link
                end
            end
        end
    end
end

---@param path string
---@return vnode|nil
---@return string|nil
---@return vnode|nil
function vfs.attributes(path)
    local current = vfs_root
    if not current then return nil, nil, nil end
    if path == "/" then return current, nil, current end

    path = vfs.resolve(path)
    local norm_path = vfs.canonical(path)
    local parts = vfs.segments(norm_path)

    local mount_node = current
    local relative_parts = {}

    for i, name in ipairs(parts) do
        local name_hash = fnv1a_hash(name)
        local next_node = current.children[name_hash]

        if not next_node then
            for _, node in pairs(current.children) do
                if node.name == name then
                    next_node = node; break
                end
            end
        end

        if not next_node then
            local parent_fs = current.fs or (mount_node and mount_node.fs)
            if parent_fs then
                local fs_path = getFsRelativePath(current)
                local child_fs_path
                if fs_path == "/" then
                    child_fs_path = "/" .. name
                else
                    child_fs_path = fs_path .. "/" .. name
                end

                if parent_fs.exists(child_fs_path) then
                    local isDir = parent_fs.isDirectory(child_fs_path)
                    next_node = createVNode(
                        name,
                        isDir and "VDIR" or "VREG",
                        current,
                        parent_fs
                    )
                    if isDir then
                        loadDirMetadata(child_fs_path, next_node, parent_fs)
                    end
                end
            end
            if not next_node then return nil, nil, nil end
        end

        if next_node.type == "VLNK" and next_node.link then
            local link_path
            if type(next_node.link) == "string" then
                link_path = next_node.link
            else
                link_path = vfs.realPath(next_node.link)
            end

            local rest_parts = {}
            for j = i + 1, #parts do
                table.insert(rest_parts, parts[j])
            end

            local new_path
            if #rest_parts > 0 then
                new_path = vfs.canonical(link_path .. "/" .. table.concat(rest_parts, "/"))
            else
                new_path = vfs.canonical(link_path)
            end
            return vfs.attributes(new_path)
        end

        current = next_node

        if current.fs then
            mount_node     = current
            relative_parts = {}
        else
            table.insert(relative_parts, name)
        end
    end

    local relative_path = #relative_parts > 0 and table.concat(relative_parts, "/") or nil
    return current, relative_path, mount_node
end

---@param vnode vnode
---@return string
function vfs.realPath(vnode)
    if not vnode then return nil end
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

---@param filter string
---@return table|nil
---@return string|nil
function vfs.proxy(filter)
    for c in component.list("filesystem") do
        if component.invoke(c, "getLabel") == filter then
            return component.proxy(c)
        end
    end
    local ok, proxy = pcall(component.proxy, filter)
    if ok then return proxy else return nil, "No such component" end
end

---@param fs oc_component_fs
---@param path string
---@return boolean
---@return string|nil
function vfs.mount(fs, path)
    if type(fs) == "string" then fs = vfs.proxy(fs) end
    assert(type(fs) == "table", "bad argument #1 (file system proxy or address expected)")

    path = vfs.resolve(path)

    if path ~= "/" and vfs.exists(path) then
        return false, "Not a directory"
    end
    local vnode = vfs.attributes(path)
    if vnode and vnode.fs then return false, "Already mounted" end

    local parent = nil
    if path ~= "/" then
        parent = vfs.attributes(vfs.path(path))
    end
    vnode = createVNode(vfs.name(path), "VDIR", parent, fs)
    if path == "/" then
        vtab[vfs_root_hash] = vnode
        vfs_root = vnode
    end
    return true
end

---@return function
function vfs.mounts()
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
        if node.fs then
            table.insert(mounts, { fs = node.fs, path = build_path(node) })
        end
        if node.children then
            for _, child in pairs(node.children) do
                collect_mounts(child)
            end
        end
    end
    local root = vfs_root
    if root then collect_mounts(root) end
    local i, n = 0, #mounts
    return function()
        i = i + 1
        if i <= n then return mounts[i].fs, mounts[i].path end
    end
end

---@param fsOrPath oc_component_fs|string
---@return boolean
function vfs.umount(fsOrPath)
    if type(fsOrPath) == "string" then
        local vnode = vfs.attributes(fsOrPath)
        if vnode and vnode.fs then
            vnode.fs = nil
            removeEmptyNodes(vnode)
            return true
        end
    end
    local addr   = type(fsOrPath) == "table" and fsOrPath.address or fsOrPath
    local result = false
    for proxy, path in vfs.mounts() do
        local maddr = type(proxy) == "table" and proxy.address or fsOrPath
        if string.sub(maddr, 1, addr:len()) == addr then
            local vnode = vfs.attributes(path)
            vnode.fs = nil
            removeEmptyNodes(vnode)
            result = true
        end
    end
    return result
end

---@param path string
---@return boolean
---@return string|nil
function vfs.isLink(path)
    local vnode = vfs.attributes(path)
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
    if vfs.attributes(linkpath) then return false, "File exists" end

    local targetNode = vfs.attributes(target)
    if not targetNode then return false, "No such file or directory" end

    local parentPath = vfs.path(linkpath)
    local parentNode = vfs.attributes(parentPath)
    if not parentNode then return false, "Parent directory does not exist" end

    local name = vfs.name(linkpath)
    local hash = fnv1a_hash(name)
    parentNode.children[hash] = {
        name     = name,
        hash     = hash,
        type     = "VLNK",
        mtime    = getRealTime(),
        btime    = getRealTime(),
        mode     = 0777,
        children = setmetatable({}, { __mode = "v" }),
        refcount = 1,
        uid      = 0,
        gid      = 0,
        link     = targetNode,
    }
    vfs._dirty = true
    return true
end

---@param path string
---@return string|nil
---@return string|nil
function vfs.readlink(path)
    path = vfs.resolve(path)
    local vnode = vfs.attributes(path)
    if not vnode then return nil, "No such file or directory" end
    if vnode.type ~= "VLNK" or not vnode.link then return nil, "Not a symbolic link" end
    if type(vnode.link) == "string" then return vnode.link end
    return vfs.realPath(vnode.link)
end

---@param path string
---@return oc_component_fs|nil
---@return string|nil
function vfs.get(path)
    local vnode = vfs.attributes(path)
    if vnode and vnode.fs then
        local proxy = vnode.fs
        path = ""
        while vnode and vnode.parent do
            path  = vfs.concat(vnode.name, path)
            vnode = vnode.parent
        end
        path = vfs.canonical(path)
        if path ~= "/" then path = "/" .. path end
        return proxy, path
    end
    return nil, "No such file system"
end

---@param path string
---@return boolean
function vfs.exists(path)
    path = vfs.resolve(path)
    return vfs.attributes(path) ~= nil
end

---@param path string
---@return integer
function vfs.size(path)
    local vnode = vfs.attributes(path)
    if vnode and vnode.fs then
        return vnode.fs.size(getFsRelativePath(vnode))
    end
    return 0
end

---@param path string
---@return boolean
function vfs.isDirectory(path)
    path = vfs.resolve(path)
    local vnode = vfs.attributes(path)
    if not vnode then return false end
    if vnode.type == "VLNK" and vnode.link then
        if type(vnode.link) == "string" then
            local target = vfs.attributes(vnode.link)
            return target ~= nil and target.type == "VDIR"
        end
        return vnode.link.type == "VDIR"
    end
    return vnode.type == "VDIR"
end

---@param path string
---@return integer
function vfs.lastModified(path)
    local vnode = vfs.attributes(path)
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
    local vnode, _, mp = vfs.attributes(path)
    if not vnode or not mp then return nil, "No such file or directory" end

    -- シンボリックリンクを解決
    if vnode.type == "VLNK" then
        if not vnode.link then return nil, "Invalid link" end
        if type(vnode.link) == "string" then
            vnode = vfs.attributes(vnode.link)
            if not vnode then return nil, "Broken link" end
        else
            vnode = vnode.link
        end
    end

    -- FSに直接問い合わせてリストを取得（childrenキャッシュに依存しない）
    local fs_path = getFsRelativePath(vnode)
    local entries = mp.fs.list(fs_path)
    if not entries then return nil, "No such file or directory" end

    local list = {}
    for _, name in ipairs(entries) do
        -- 末尾スラッシュを除去し.metaを除外
        name = name:gsub("/*$", "")
        if name ~= ".meta" and name ~= "" then
            table.insert(list, name)
        end
    end
    table.sort(list)

    local i = 0
    return function()
        i = i + 1
        return list[i]
    end
end

---@param path string
---@return boolean
---@return string|nil
function vfs.makeDirectory(path)
    path = vfs.resolve(path)
    local parent_vnode, rest, mp = vfs.attributes(vfs.path(path))
    if vfs.exists(path) or not (parent_vnode and mp) then
        return false, "File exists"
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
        createVNode(vfs.name(path), "VDIR", parent_vnode, mp.fs)
        vfs._dirty = true
        return true
    end
    return false, e
end

---@param path string
---@return boolean
---@return string|nil
function vfs.remove(path)
    path = vfs.resolve(path)
    local parent_vnode, rest, mp = vfs.attributes(vfs.path(path))

    if not vfs.can(vfs.path(path), "w") or not vfs.can(vfs.path(path), "x") then
        return false, "Permission Denied"
    end

    local function vremove()
        if not parent_vnode then return false, "No such file or directory" end
        local name_hash = fnv1a_hash(vfs.name(path))
        if parent_vnode.children[name_hash] then
            parent_vnode.children[name_hash] = nil
            removeEmptyNodes(parent_vnode)
            return true
        end
        return false, "No such file or directory"
    end

    local function premove()
        local target_vnode = vfs.attributes(path)
        if target_vnode and target_vnode.fs then
            return target_vnode.fs.remove(getFsRelativePath(target_vnode))
        end
        return false, "No such file or directory"
    end

    local s, e   = vremove()
    local ps, pe = premove()
    s            = s or ps
    e            = pe or e
    if s then vfs._dirty = true end
    return s, e
end

function vfs.rename(oldPath, newPath)
    -- TODO
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

    local vnode, rest, mp = vfs.attributes(path)
    if not vnode then
        local parent, _, parentMp = vfs.attributes(vfs.path(path))
        if string.find(mode, "w") and parent and parentMp then
            vnode = createVNode(vfs.name(path), "VREG", parent, parentMp.fs)
            mp    = parentMp
        else
            return nil, "No such file or directory"
        end
    end

    if not mp then return nil, "No mount point found for path" end

    local abs_path = vfs.realPath(vnode) or path
    if not vfs.can(abs_path, mode:find("r") and "r" or "w") then
        return nil, "Permission denied"
    end

    local fs_path        = getFsRelativePath(vnode)
    local handle, reason = mp.fs.open(fs_path, mode)
    if not handle then return nil, reason end

    ---@class vfs_handle
    local file = { fs = mp.fs, handle = handle }
    vhandles[tostring(handle)] = { fs = mp.fs, fd = handle, vnode = vnode, flag = mode }

    function file:close()
        if self.handle then
            self.fs.close(self.handle)
            vhandles[tostring(self.handle)] = nil
            self.handle = nil
        else
            error("file is already closed")
        end
    end

    function file:read(n)
        if not self.handle then return nil, "file is closed" end
        return self.fs.read(self.handle, n)
    end

    function file:readAll()
        -- use string to reduce memory usage (tables and table.concat uses additional memories)
        local chunks = ""
        while true do
            local chunk, err = self.fs.read(self.handle, 8192)
            if not chunk then
                if err then
                    error("fs: error while reading: " .. err)
                end
                break
            end
            chunks = chunks .. chunk
        end
        return chunks
    end

    function file:seek(whence, offset)
        if not self.handle then return nil, "file is closed" end
        return self.fs.seek(self.handle, whence, offset)
    end

    function file:write(str)
        if not self.handle then return nil, "file is closed" end
        return self.fs.write(self.handle, str)
    end

    local function close(self)
        if self.handle then
            if pcall(self.fs.close, self.handle) then
                vhandles[tostring(self.handle)] = nil
                self.handle = nil
            end
        end
    end
    setmetatable(file, {
        __gc    = function(self) close(self) end,
        __close = function(self) close(self) end,
    })
    return file
end

---@param path string
---@param mode integer
function vfs.chmod(path, mode)
    path = vfs.resolve(path)
    if not mode then return nil, "Mode does not specified" end

    local vnode = vfs.attributes(path)
    if not vnode then return nil, "No such file or directory" end

    local proc      = process.getCurrent()
    local canModify = false
    if not proc then
        canModify = (process.getCurrentPID() == -1)
    else
        canModify = (proc.euid == 0) or (proc.euid == vnode.uid)
    end

    if not canModify then return nil, "Permission denied" end

    vnode.mode = mode
    vfs._dirty = true
end

---@param path string
---@param uid integer
---@param gid integer
function vfs.chown(path, uid, gid)
    path = vfs.resolve(path)
    if not uid or not gid then return nil, "UID or GID does not specified" end

    local vnode = vfs.attributes(path)
    if not vnode then return nil, "No such file or directory" end

    local proc      = process.getCurrent()
    local canModify = false
    if not proc then
        canModify = (process.getCurrentPID() == -1)
    else
        canModify = (proc.euid == 0) or (proc.euid == vnode.uid)
    end

    if not canModify then return nil, "Permission denied" end

    vnode.uid = uid
    vnode.gid = gid
    vfs._dirty = true
end

local function writeMeta(dirPath, children, fs)
    if fs.isReadOnly and fs.isReadOnly() then return end

    local meta = ""
    for _, child in pairs(children) do
        local linkPath = ""
        if child.type == "VLNK" and child.link then
            if type(child.link) == "string" then
                linkPath = child.link
            else
                linkPath = vfs.realPath(child.link) or ""
            end
        end
        meta = meta .. string.format("%s:%s:%d:%d:%d:%d:%d:%d:%d:%s\n",
            child.name,
            child.type,
            child.hash,
            math.floor(child.mtime),
            math.floor(child.btime),
            child.mode,
            child.refcount or 1,
            child.uid,
            child.gid,
            linkPath)
    end

    local metaPath = (dirPath == "/" and "" or dirPath) .. "/.meta"
    local handle   = fs.open(metaPath, "w")
    if handle then
        fs.write(handle, meta)
        fs.close(handle)
    end
end

function vfs.saveMetadata()
    local function saveDir(vnode)
        local fs = vnode.fs
        if not fs then return end
        if fs.isReadOnly and fs.isReadOnly() then return end

        local path = vfs.realPath(vnode)
        if not path or not vnode.children then return end

        writeMeta(path, vnode.children, fs)

        for _, child in pairs(vnode.children) do
            if child.type == "VDIR" and child.fs == fs then
                saveDir(child)
            end
        end
    end

    if vfs_root then saveDir(vfs_root) end
    return true
end

-- lookupFilesystemは互換性のため残すが、mount()からは呼ばれない
-- 必要な場合のみ明示的に呼び出す
---@param basePath string
---@param fs oc_component_fs
function vfs.lookupFilesystem(basePath, fs)
    local base = vfs.attributes(basePath)
    if not base then
        error("Invalid basePath " .. basePath)
    end

    local function lookup(path, parent)
        local entries = fs.list(path)
        if not entries then return end

        local subdirs = {}
        for _, name in ipairs(entries) do
            name = name:gsub("^/*", ""):gsub("/*$", "")
            if name ~= ".meta" then
                local dpath = vfs.concat(path, name)
                printk("vfs: indexing '" .. dpath .. "'")
                local isDir = fs.isDirectory(dpath)
                local vnode = createVNode(name, isDir and "VDIR" or "VREG", parent, fs)
                if isDir then
                    table.insert(subdirs, { path = dpath, vnode = vnode })
                end
            end
        end

        loadDirMetadata(path, parent, fs)

        for _, sub in ipairs(subdirs) do
            lookup(sub.path, sub.vnode)
        end
    end

    lookup("/", base)
end

---@param handle integer
---@param value any
function vfs.write(handle, value)
    local desc = vhandles[tostring(handle)]
    if not desc then return nil, "Bad file descriptor" end
    if desc.vnode and desc.vnode.type == "VCHR" then
        return devfs.write(handle, value)
    end
    return desc.fs.write(handle, value)
end

---@param handle integer
---@param n integer
function vfs.read(handle, n)
    local desc = vhandles[tostring(handle)]
    if not desc then return nil, "Bad file descriptor" end
    if desc.vnode and desc.vnode.type == "VCHR" then
        return devfs.read(handle, n)
    end
    return desc.fs.read(handle, n)
end

---@param handle integer
function vfs.close(handle)
    local desc = vhandles[tostring(handle)]
    if not desc then return nil, "Bad file descriptor" end
    local result
    if desc.vnode and desc.vnode.type == "VCHR" then
        result = devfs.close(handle)
    else
        result = desc.fs.close(handle)
    end
    vhandles[tostring(handle)] = nil
    return result
end

---@param parentPath string
---@param name string
---@param vtype vtype
---@param fs? oc_component_fs
---@param perm? integer
---@return vnode|nil
---@return string|nil
function vfs.createVNode(parentPath, name, vtype, fs, perm)
    if vfs.attributes(vfs.concat(parentPath, name)) then
        return nil, "VNode in the specified path already exists"
    end
    local parent = vfs.attributes(parentPath)
    if not parent then
        return nil, "Parent VNode does not exist"
    end
    return createVNode(name, vtype, parent, fs, perm)
end

---@param filename string
---@param mode? string
---@param env? table
loadfile = function(filename, mode, env)
    local file, err = vfs.open(filename, "r")
    if not file then return nil, err end

    local chunks = {}
    local buffer_size = 8192

    while true do
        local data, reason = file:read(buffer_size)

        if not data then
            if reason then
                file:close()
                return nil, reason
            end
            break
        end

        table.insert(chunks, data)
    end
    file:close()

    local buffer = table.concat(chunks)
    chunks = nil

    local chunk, load_err = load(buffer, "=" .. filename, mode or "bt", env or (util and util.createEnv() or _G))
    if not chunk then return nil, load_err end
    return chunk
end
