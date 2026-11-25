-- tests/lib/kernel.lua - kernel sources for tests, found through
-- properties.lua so tests do not depend on where a source lives.
--
--   local kernel = dofile("tests/lib/kernel.lua")
--   kernel.path("devfs")     -- "src/fs/devfs.lua" (a part that is one file)
--   kernel.read("devfs")     -- its text
--   kernel.source("vfs")     -- every source of a part, in build order, each
--                            -- in its own do ... end block as in the kernel
--
-- A part is named by a source's file name without .lua (devfs, klog) or by
-- a directory of sources (vfs = src/fs/vfs/*, process = src/proc/process/*).

local kernel = {}

local props = dofile("properties.lua")

local function sourcesOf(name)
    local out = {}
    for _, include in ipairs(props.includes) do
        local base = include:match("([^/]+)%.lua$")
        if base == name or ("/" .. include):find("/" .. name .. "/", 1, true) then
            out[#out + 1] = props.includeDir .. "/" .. include
        end
    end
    if #out == 0 then error("no kernel source named " .. name, 2) end
    return out
end

local function readFile(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("a")
    file:close()
    return text
end

function kernel.path(name)
    local paths = sourcesOf(name)
    if #paths ~= 1 then error(name .. " is " .. #paths .. " sources; use kernel.source", 2) end
    return paths[1]
end

function kernel.read(name)
    return readFile(kernel.path(name))
end

function kernel.source(name)
    local parts = {}
    for _, path in ipairs(sourcesOf(name)) do
        parts[#parts + 1] = "do -- " .. path .. "\n" .. readFile(path) .. "\nend\n"
    end
    return table.concat(parts)
end

return kernel
