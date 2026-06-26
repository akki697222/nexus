local function usage()
    io.stderr:write("usage: realpath FILE...\n")
    return 1
end

local function main(...)
    local paths = {...}
    if #paths == 0 then
        return usage()
    end

    for _, path in ipairs(paths) do
        local resolved = vfs.realPath(path)
        if not resolved then
            io.stderr:write("realpath: " .. path .. ": No such file or directory\n")
            return 1
        end
        io.write(resolved, "\n")
    end

    return 0
end

os.exit(main(...))
