---@class io
local io = {}

function io.write(...)
    devfs.write(1, ...)
end

function io.read(...)
    return devfs.read(0, ...)
end

io.stdin = {
    read = function(self, ...)
        return devfs.read(0, ...)
    end,
    readLine = function(self)
        return devfs.read(0, "*l")
    end,
    close = function(self, ...) end,
    tty = true
}

io.stdout = {
    read = function(self, ...) return nil end,
    readLine = function(self, ...) return nil end,
    write = function(self, ...)
        devfs.write(1, ...)
    end,
    close = function(self, ...) end,
    tty = true
}

io.stderr = {
    read = function(self, ...) return nil end,
    readLine = function(self, ...) return nil end,
    write = function(self, ...)
        devfs.write(2, ...)
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
    -- カーネルからユーザーランドライブラリを呼び出す
    local pipe_lib = require("pipe")
    mode = mode or "r"

    local r, w = pipe_lib.new()
    local my_handle, child_fd_entry

    local function wrap(handle, flag)
        local obj = {}
        if flag == "r" then
            function obj:read(...)
                return handle.fs.read(handle, ...)
            end
        else
            function obj:write(...)
                return handle.fs.write(handle, ...)
            end
        end
        function obj:close() handle.fs.close(handle) end

        return obj
    end

    if mode == "r" then
        my_handle = wrap(r, "r")
        child_fd_entry = { fd = w, flag = "w" }
    elseif mode == "w" then
        my_handle = wrap(w, "w")
        child_fd_entry = { fd = r, flag = "r" }
    else
        return nil, "invalid mode"
    end

    -- Spawn shell to run command
    -- Using process.exec to run sh.lua directly
    local pid = process.exec("/usr/bin/sh.lua", { "-c", prog })

    if pid and pid > 0 then
        local proc = process.get(pid)
        if proc then
            -- Inject pipe into child process FD
            local vnode = { fs = child_fd_entry.fd.fs, name = "popen_pipe", is_pipe = true }
            local target_fd = (mode == "r") and 2 or 1 -- 2=stdout(index 2 in fd table is fd 1), 1=stdin(index 1 is fd 0)

            proc.fd[target_fd] = {
                vnode = vnode,
                fd = child_fd_entry.fd,
                flag = child_fd_entry.flag
            }
        end
    else
        return nil, "failed to spawn process"
    end

    return my_handle
end
