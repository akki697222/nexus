---@class io
local io = {}

-- io functions act on descriptors 0/1/2 of the calling process
local function joinArgs(...)
    local n = select("#", ...)
    if n == 1 then return (...) end
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts)
end

function io.write(...)
    return vfs.write(1, joinArgs(...))
end

function io.read(...)
    return vfs.read(0, ...) or ""
end

function io.isatty(fd)
    return vfs.isatty(fd)
end

io.stdin = {
    read = function(self, ...)
        return vfs.read(0, ...)
    end,
    readLine = function(self)
        return vfs.read(0, "*l")
    end,
    close = function(self, ...) end,
    tty = true
}

io.stdout = {
    read = function(self, ...) return nil end,
    readLine = function(self, ...) return nil end,
    write = function(self, ...)
        return vfs.write(1, joinArgs(...))
    end,
    close = function(self, ...) end,
    tty = true
}

io.stderr = {
    read = function(self, ...) return nil end,
    readLine = function(self, ...) return nil end,
    write = function(self, ...)
        return vfs.write(2, joinArgs(...))
    end,
    close = function(self, ...) end,
    tty = true
}

function io.open(path, mode)
    return vfs.open(path, mode)
end

---@param prog string
---@param mode string
---@return table|nil
---@return string|nil
function io.popen(prog, mode)
    if type(prog) ~= "string" then return nil, "command must be a string" end
    mode = mode or "r"
    if mode ~= "r" and mode ~= "w" then return nil, "invalid mode" end

    local readFd, writeFd = vfs.pipe()
    if not readFd then return nil, writeFd end
    local reading = mode == "r"
    local keep = reading and readFd or writeFd
    local child = reading and writeFd or readFd
    local destination = reading and 1 or 0
    local pid, err, instance = process.spawn("/usr/bin/sh.lua", { "-c", prog }, { [destination] = child })
    vfs.close(child)
    if not pid or pid == -1 then
        vfs.close(keep)
        return nil, err or "failed to spawn process"
    end

    local owner = process.getCurrent()
    local original = descriptor(keep)
    local closed = false
    local handle = {}
    local function isOpen()
        return not closed and process.getCurrent() == owner and descriptor(keep) == original
    end

    if reading then
        function handle:read(...)
            if not isOpen() then return nil, "file is closed" end
            return vfs.read(keep, ...)
        end
    else
        function handle:write(...)
            if not isOpen() then return nil, "file is closed" end
            return vfs.write(keep, joinArgs(...))
        end
    end

    function handle:close()
        if closed or process.getCurrent() ~= owner then return nil, "file is closed" end
        if isOpen() then vfs.close(keep) end
        closed = true
        local waitErr, status = process.wait(pid, instance)
        if waitErr then return nil, waitErr end
        if status == 0 then return true, "exit", 0 end
        return nil, "exit", status
    end

    return handle
end
