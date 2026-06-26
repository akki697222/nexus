---@class procfs : oc_component_fs
local procfs = {}

local virtual_files = {}

local handles = {}
local next_handle = 100

local function def(path, fn)
    virtual_files[path] = fn
end

def("/meminfo", function()
    local total = computer.totalMemory()
    local free  = computer.freeMemory()
    local used  = total - free
    return string.format(
        "MemTotal:  %8d kB\nMemFree:   %8d kB\nMemUsed:   %8d kB\n",
        math.floor(total / 1024),
        math.floor(free  / 1024),
        math.floor(used  / 1024)
    )
end)

def("/uptime", function()
    local up = computer.uptime()
    return string.format("%.2f %.2f\n", up, up * 0.9)
end)

def("/version", function()
    return string.format("%s version %s (%s)\n",
        _OSNAME or "Nexus",
        _OSVERSIONSTRING or "unknown",
        _MACHINE or "OpenComputers"
    )
end)

def("/mounts", function()
    local lines = {}
    for proxy, path in vfs.mounts() do
        local label   = (type(proxy) == "table" and proxy.getLabel and proxy.getLabel()) or "?"
        local ro_rw   = (type(proxy) == "table" and proxy.isReadOnly and proxy.isReadOnly()) and "ro" or "rw"
        local address = (type(proxy) == "table" and proxy.address) or tostring(proxy)
        table.insert(lines, string.format("%s %s ocfs %s 0 0\n", address:sub(1, 8), path, ro_rw))
    end
    return table.concat(lines)
end)

local function proc_status(pid)
    local proc = process.get(pid)
    if not proc then return nil end
    local lines = {
        string.format("Name:\t%s\n",   vfs.name(proc.path or "?")),
        string.format("Pid:\t%d\n",    proc.pid),
        string.format("PPid:\t%d\n",   proc.parent or 0),
        string.format("Pgid:\t%d\n",   proc.pgid or 0),
        string.format("State:\t%s\n",  proc.status or "?"),
        string.format("Uid:\t%d\t%d\t%d\n", proc.uid or 0, proc.euid or 0, proc.suid or 0),
        string.format("Gid:\t%d\t%d\t%d\n", proc.gid or 0, proc.egid or 0, proc.sgid or 0),
        string.format("Nice:\t%d\n",   proc.nice or 3),
        string.format("Tty:\t%d\n",    proc.tty or -1),
    }
    return table.concat(lines)
end

local function proc_cmdline(pid)
    local proc = process.get(pid)
    if not proc then return nil end
    local parts = { proc.path or "" }
    for _, a in ipairs(proc.arguments or {}) do
        table.insert(parts, tostring(a))
    end
    return table.concat(parts, "\0") .. "\n"
end

local function proc_environ(pid)
    local proc = process.get(pid)
    if not proc then return nil end
    local lines = {}
    for k, v in pairs(proc.environ or {}) do
        table.insert(lines, k .. "=" .. tostring(v) .. "\0")
    end
    return table.concat(lines) .. "\n"
end

local function proc_fd_list(pid)
    local proc = process.get(pid)
    if not proc then return nil end
    local lines = {}
    for i, desc in ipairs(proc.fd or {}) do
        local name = "?"
        if desc.vnode then
            name = vfs.realPath and vfs.realPath(desc.vnode) or (desc.vnode.name or "?")
        end
        table.insert(lines, string.format("%d -> %s (%s)\n", i - 1, name, desc.flag or "?"))
    end
    return table.concat(lines)
end

local function parse_path(path)
    if not path or path == "/" or path == "" then
        return nil, nil
    end
    path = path:gsub("^/+", "")
    local first, rest = path:match("^([^/]+)/?(.*)$")
    if not first then return nil, nil end

    local pid = tonumber(first)
    if pid then
        return pid, (rest ~= "" and ("/" .. rest) or nil)
    end

    if first == "self" then
        local cur = process.getCurrent()
        local cur_pid = cur and cur.pid or -1
        return cur_pid, (rest ~= "" and ("/" .. rest) or nil)
    end

    return nil, "/" .. first .. (rest ~= "" and ("/" .. rest) or "")
end

local function get_content(path)
    local pid, sub = parse_path(path)

    if pid then
        if sub == nil then return nil end
        if sub == "/status"  then return proc_status(pid)  end
        if sub == "/cmdline" then return proc_cmdline(pid) end
        if sub == "/environ" then return proc_environ(pid) end
        if sub == "/fd"      then return proc_fd_list(pid) end
        return nil
    end

    if sub and virtual_files[sub] then
        return virtual_files[sub]()
    end
    return nil
end

function procfs.spaceUsed()  return 0 end
function procfs.spaceTotal() return 0 end
function procfs.isReadOnly() return true end
function procfs.getLabel()   return "procfs" end
function procfs.setLabel(v)  return "procfs" end

function procfs.exists(path)
    if path == "/" or path == "" or path == "." then return true end

    local pid, sub = parse_path(path)
    if pid then
        if not process.get(pid) then return false end
        local valid = { ["/status"]=true, ["/cmdline"]=true, ["/environ"]=true, ["/fd"]=true }
        return valid[sub] == true
    end
    if sub then
        return virtual_files[sub] ~= nil
    end
    return false
end

function procfs.isDirectory(path)
    if path == "/" or path == "" or path == "." then return true end

    local pid, sub = parse_path(path)
    if pid and sub == nil then return true end
    return false
end

function procfs.list(path)
    if path == "/" or path == "" or path == "." then
        local result = {}
        for _, proc in ipairs(process.list()) do
            table.insert(result, tostring(proc.pid))
        end
        table.insert(result, "self")
        for name, _ in pairs(virtual_files) do
            local stripped = name:gsub("^/", "")
            table.insert(result, stripped)
        end
        table.sort(result)
        return result
    end

    local pid = parse_path(path)
    if pid and process.get(pid) then
        return { "status", "cmdline", "environ", "fd" }
    end

    return nil
end

function procfs.size(path)
    local content = get_content(path)
    return content and #content or 0
end

function procfs.lastModified(path)
    return math.floor(computer.uptime() * 1000)
end

function procfs.makeDirectory(path)
    return false, "Read-only file system"
end

function procfs.remove(path)
    return false, "Read-only file system"
end

function procfs.rename(from, to)
    return false, "Read-only file system"
end

function procfs.open(path, mode)
    if mode and (mode:find("w") or mode:find("a")) then
        return nil, "Read-only file system"
    end

    local content = get_content(path)
    if content == nil then
        return nil, "No such file or directory"
    end

    local handle = next_handle
    next_handle = next_handle + 1
    handles[tostring(handle)] = { content = content, pos = 1 }
    return handle
end

function procfs.read(handle, count)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    if h.pos > #h.content then return nil end

    count = math.min(count, #h.content - h.pos + 1)
    local data = h.content:sub(h.pos, h.pos + count - 1)
    h.pos = h.pos + count
    return data
end

function procfs.seek(handle, whence, offset)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    offset = offset or 0

    if whence == "set" then
        h.pos = 1 + offset
    elseif whence == "cur" then
        h.pos = h.pos + offset
    elseif whence == "end" then
        h.pos = #h.content + 1 + offset
    else
        return nil, "Invalid whence"
    end
    h.pos = math.max(1, math.min(h.pos, #h.content + 1))
    return h.pos - 1
end

function procfs.write(handle, value)
    return nil, "Read-only file system"
end

function procfs.close(handle)
    handles[tostring(handle)] = nil
end