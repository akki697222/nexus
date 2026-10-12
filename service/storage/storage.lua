-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- storage_service: owns the OC filesystem components, drive aliases and
-- path resolution ("System://Exec/x.lua" -> component address + path).

---@type storage
storage = {}

---@type table<string, volume_entry>
local volumes = {}

local ALIAS_PATTERN = "^([%w_%-]+)://(.*)$"

local function component_type(addr)
    local ok, t = pcall(component.type, addr)
    return ok and t or nil
end

---@param root string?  # directory of the component that becomes the volume root
function storage.mount(addr, alias, root)
    arg(1, addr,  "string")
    arg(2, alias, "string")
    arg(3, root,  "string", true)
    if not alias:match("^[%w_%-]+$") then
        error("invalid drive alias '" .. alias .. "'", 2)
    end
    if volumes[alias] then
        error("alias '" .. alias .. "' is already mounted", 2)
    end
    if component_type(addr) ~= "filesystem" then
        error("no filesystem component at '" .. addr .. "'", 2)
    end
    local proxy = component.proxy(addr)
    root = root and storage.normalize(root) or "/"
    if root ~= "/" and not proxy.exists(root) then
        proxy.makeDirectory(root)
    end
    volumes[alias] = { alias = alias, addr = addr, proxy = proxy, root = root }
    log.info("[storage] mounted %s -> %s%s", alias, addr:sub(1, 8), root ~= "/" and root or "")
end

function storage.unmount(alias)
    arg(1, alias, "string")
    if volumes[alias] then
        volumes[alias] = nil
        log.info("[storage] unmounted %s", alias)
    end
end

function storage.list_volumes()
    local copy = {}
    for k, v in pairs(volumes) do copy[k] = v end
    return copy
end

function storage.get_by_alias(alias)
    arg(1, alias, "string")
    return volumes[alias]
end

function storage.get_by_addr(addr)
    arg(1, addr, "string")
    for _, v in pairs(volumes) do
        if v.addr == addr then return v end
    end
    return nil
end

---Split "Alias://rest" into alias, rest. Returns nil for alias-less paths.
function storage.parse(path)
    arg(1, path, "string")
    return path:match(ALIAS_PATTERN)
end

---Collapse "." / ".." / duplicate slashes. Returns "/a/b" (always absolute
---within the volume) or nil, err if the path escapes the volume root.
function storage.normalize(rest)
    arg(1, rest, "string")
    local parts = {}
    for seg in rest:gmatch("[^/]+") do
        if seg == "." then
            -- skip
        elseif seg == ".." then
            if #parts == 0 then return nil, "path escapes volume root" end
            parts[#parts] = nil
        else
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

---Make a path absolute using the current process's cwd.
---@return string? alias, string rest_or_err
function storage.absolute(path)
    arg(1, path, "string")
    local alias, rest = storage.parse(path)
    if alias then return alias, rest end

    local proc = process_manager.current_proc()
    local cwd  = proc and proc.cwd or "System://"
    local calias, crest = storage.parse(cwd)
    if not calias then return nil, "invalid cwd '" .. cwd .. "'" end
    if path:sub(1, 1) == "/" then return calias, path end
    return calias, crest .. "/" .. path
end

---Resolve to (volume_entry, normalized path inside that volume).
function storage.locate(path)
    local alias, rest = storage.absolute(path)
    if not alias then return nil, rest end
    local vol = volumes[alias]
    if not vol then return nil, "drive '" .. alias .. "' is not mounted" end
    local rel, err = storage.normalize(rest)
    if not rel then return nil, err end
    -- rel is confined to the volume (".." was resolved above); add the mount root
    if vol.root ~= "/" then
        rel = vol.root .. (rel == "/" and "" or rel)
    end
    return vol, rel
end

function storage.resolve(path)
    local vol, rel = storage.locate(path)
    if not vol then error(rel, 2) end
    return "/Volumes/" .. vol.addr .. (rel == "/" and "" or rel)
end

-- ------------------------------------------------------------
--  Boot: mount boot / tmp / other filesystems
-- ------------------------------------------------------------

local boot = computer.getBootAddress()
-- Boot://   core system (kernel-loaded services); System:// user space under /System
storage.mount(boot, "Boot")
storage.mount(boot, "System", "/System")

local tmp = computer.tmpAddress and computer.tmpAddress()
if tmp and tmp ~= boot then
    storage.mount(tmp, "Temp")
end

local n = 0
for addr in component.list("filesystem") do
    if addr ~= boot and addr ~= tmp then
        n = n + 1
        storage.mount(addr, n == 1 and "Data" or ("Data" .. n))
    end
end

log.info("[storage] ready (%d volumes)", n + 2 + (tmp and 1 or 0))
service_manager.ready("storage")
while true do
    event.pull()
end
