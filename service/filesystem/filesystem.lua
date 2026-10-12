-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- filesystem_service: VFS (vnode) + Stream capability + fs.* API.
-- Calls run in the caller's coroutine (shared runtime), so stream
-- capabilities are owned by - and closed with - the calling process.

local CHUNK = 2048 -- OC read buffer is limited; also keeps writes small

-- ------------------------------------------------------------
--  Stream capability
-- ------------------------------------------------------------

local function fill(core)
    if core.eof then return false end
    local data = core.proxy.read(core.handle, CHUNK)
    if not data then
        core.eof = true
        return false
    end
    core.buf = core.buf .. data
    return true
end

local function read_all(core)
    local parts = { core.buf }
    core.buf = ""
    while not core.eof do
        local data = core.proxy.read(core.handle, CHUNK)
        if not data then
            core.eof = true
        else
            parts[#parts + 1] = data
        end
    end
    return table.concat(parts)
end

capability.register("stream", {
    ops = { "read", "write", "close" },
    new = function(proxy, handle, path)
        local core = { proxy = proxy, handle = handle, path = path, buf = "", eof = false, closed = false }

        function core.read(_, fmt)
            if fmt == nil then fmt = "a" end
            if type(fmt) == "string" then fmt = fmt:gsub("^%*", "") end
            if fmt == "a" then
                return read_all(core)
            elseif fmt == "l" or fmt == "L" then
                while not core.buf:find("\n", 1, true) do
                    if not fill(core) then break end
                end
                if core.buf == "" then return nil end
                local nl = core.buf:find("\n", 1, true)
                local line
                if nl then
                    line = core.buf:sub(1, fmt == "L" and nl or nl - 1)
                    core.buf = core.buf:sub(nl + 1)
                else
                    line = core.buf
                    core.buf = ""
                end
                return line
            elseif type(fmt) == "number" then
                while #core.buf < fmt do
                    if not fill(core) then break end
                end
                if core.buf == "" and fmt > 0 then return nil end
                local out = core.buf:sub(1, fmt)
                core.buf = core.buf:sub(fmt + 1)
                return out
            end
            error("bad read format '" .. tostring(fmt) .. "'", 2)
        end

        function core.write(_, data)
            data = tostring(data)
            for i = 1, #data, CHUNK do
                local ok, err = core.proxy.write(core.handle, data:sub(i, i + CHUNK - 1))
                if not ok then return nil, err end
            end
            return true
        end

        function core.close()
            capability.revoke(core._mt)
        end

        return core
    end,
    dispose = function(core)
        if not core.closed then
            core.closed = true
            pcall(core.proxy.close, core.handle)
        end
    end,
})

-- ------------------------------------------------------------
--  vnode (OC filesystem backend)
-- ------------------------------------------------------------

local vnode = {}
vnode.__index = vnode

local function make_node(vol, path)
    return setmetatable({ vol = vol, path = path }, vnode)
end

local function join(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end

local function parent_of(path)
    local p = path:match("^(.*)/[^/]+$")
    if p == nil or p == "" then return "/" end
    return p
end

function vnode:exists()
    return self.vol.proxy.exists(self.path)
end

function vnode:stat()
    local p = self.vol.proxy
    if not p.exists(self.path) then
        return nil, "no such file or directory: " .. self.path
    end
    local is_dir = p.isDirectory(self.path)
    return {
        is_dir   = is_dir,
        size     = is_dir and 0 or p.size(self.path),
        modified = p.lastModified(self.path),
        readonly = p.isReadOnly(),
    }
end

function vnode:list()
    local names = self.vol.proxy.list(self.path)
    if not names then return nil, "not a directory: " .. self.path end
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = make_node(self.vol, join(self.path, (name:gsub("/$", ""))))
    end
    return out
end

function vnode:get_child(name)
    arg(1, name, "string")
    if name == "" or name:find("/", 1, true) then
        return nil, "invalid name '" .. name .. "'"
    end
    return make_node(self.vol, join(self.path, name))
end

function vnode:create(name, is_dir)
    local child, err = self:get_child(name)
    if not child then return nil, err end
    if is_dir then
        local ok = self.vol.proxy.makeDirectory(child.path)
        if not ok then return nil, "makeDirectory failed: " .. child.path end
    else
        local h, e = self.vol.proxy.open(child.path, "w")
        if not h then return nil, e end
        self.vol.proxy.close(h)
    end
    return child
end

function vnode:remove()
    if self.path == "/" then return nil, "cannot remove volume root" end
    local ok = self.vol.proxy.remove(self.path)
    if not ok then return nil, "cannot remove " .. self.path end
    return true
end

function vnode:open(mode)
    mode = mode or "r"
    local m = mode:sub(1, 1)
    if m ~= "r" and m ~= "w" and m ~= "a" then
        return nil, "invalid mode '" .. mode .. "'"
    end
    local p = self.vol.proxy
    if m == "r" then
        if not p.exists(self.path) then return nil, "no such file: " .. self.path end
        if p.isDirectory(self.path) then return nil, "is a directory: " .. self.path end
    else
        local dir = parent_of(self.path)
        if not p.exists(dir) then p.makeDirectory(dir) end
    end
    local handle, err = p.open(self.path, m)
    if not handle then return nil, err or ("cannot open " .. self.path) end
    local ops = m == "r" and { "read", "close" } or { "write", "close" }
    return (capability.create("stream", ops, p, handle, self.path))
end

-- ------------------------------------------------------------
--  fs.* API
-- ------------------------------------------------------------

fs = {}
fs.vnode = vnode

local function node_of(path)
    arg(1, path, "string")
    local vol, rel = storage.locate(path)
    if not vol then return nil, rel end
    return make_node(vol, rel)
end

---Normalized absolute path ("Alias://a/b") relative to the caller's cwd.
function fs.abspath(path)
    arg(1, path, "string")
    local alias, rest = storage.absolute(path)
    if not alias then return nil, rest end
    local rel, err = storage.normalize(rest)
    if not rel then return nil, err end
    return alias .. "://" .. rel:sub(2)
end

function fs.node(path)
    return node_of(path)
end

function fs.open(path, mode)
    local node, err = node_of(path)
    if not node then return nil, err end
    return node:open(mode)
end

function fs.stat(path)
    local node, err = node_of(path)
    if not node then return nil, err end
    return node:stat()
end

function fs.exists(path)
    local node = node_of(path)
    return node ~= nil and node:exists() or false
end

function fs.is_dir(path)
    local st = fs.stat(path)
    return st ~= nil and st.is_dir
end

---@return string[]? names
function fs.list(path)
    local node, err = node_of(path)
    if not node then return nil, err end
    local children, e = node:list()
    if not children then return nil, e end
    local names = {}
    for i, c in ipairs(children) do
        names[i] = c.path:match("([^/]+)$")
    end
    table.sort(names)
    return names
end

function fs.mkdir(path)
    local node, err = node_of(path)
    if not node then return nil, err end
    if node:exists() then return true end
    if not node.vol.proxy.makeDirectory(node.path) then
        return nil, "makeDirectory failed: " .. node.path
    end
    return true
end

function fs.remove(path)
    local node, err = node_of(path)
    if not node then return nil, err end
    return node:remove()
end

function fs.rename(from, to)
    local a, err = node_of(from)
    if not a then return nil, err end
    local b, err2 = node_of(to)
    if not b then return nil, err2 end
    if a.vol.addr ~= b.vol.addr then return nil, "cannot rename across volumes" end
    if not a.vol.proxy.rename(a.path, b.path) then return nil, "rename failed" end
    return true
end

function fs.read_file(path)
    local f, err = fs.open(path, "r")
    if not f then return nil, err end
    local data = f:read("a")
    f:close()
    return data
end

function fs.write_file(path, data, append)
    local f, err = fs.open(path, append and "a" or "w")
    if not f then return nil, err end
    local ok, e = f:write(data)
    f:close()
    if not ok then return nil, e end
    return true
end

log.info("[filesystem] ready")
service_manager.ready("filesystem")
while true do
    event.pull()
end
