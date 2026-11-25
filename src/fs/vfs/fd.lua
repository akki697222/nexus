-- vfs/fd.lua - open file descriptions and per-process descriptor tables:
-- allocation, buffered reads of regular files, inheritance on spawn/exec.

-- from the sources before this one
local openDescriptions = vfsi.openDescriptions

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
function descriptor(fd)
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

-- for the sources after this one
vfsi.releaseDescription = releaseDescription
vfsi.allocFd = allocFd
vfsi.readRegularFile = readRegularFile
vfsi.seekBufferedFile = seekBufferedFile
vfsi.fdTable = fdTable
