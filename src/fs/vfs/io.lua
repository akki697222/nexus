-- vfs/io.lua - anonymous pipes, descriptor I/O (read, write, seek, close,
-- dup, dup2, isatty), attributes and the kernel's loadfile.

-- from the sources before this one
local createVNode = vfsi.createVNode
local vnodeTimes = vfsi.vnodeTimes
local touch = vfsi.touch
local markDirty = vfsi.markDirty
local fdTable = vfsi.fdTable
local releaseDescription = vfsi.releaseDescription
local allocFd = vfsi.allocFd
local readRegularFile = vfsi.readRegularFile
local seekBufferedFile = vfsi.seekBufferedFile

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
        touch(d.vnode)
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
