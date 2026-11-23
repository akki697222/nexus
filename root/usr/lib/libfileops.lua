-- Helpers shared by cp and mv. Keep path handling inside the public VFS API.
local fs = require("filesystem")

local fileops = {}

function fileops.isReservedPath(path)
    for part in tostring(path):gmatch("[^/]+") do
        if part == ".meta" then return true end
    end
    return false
end

function fileops.basename(path)
    local name = fs.name(path)
    if name == "/" or name == "" then return nil end
    return name
end

function fileops.join(parent, name)
    return fs.concat(parent, name)
end

function fileops.isDirectory(path, attrs)
    if attrs and attrs.type == "VDIR" then return true end
    if type(fs.isDirectory) ~= "function" then return false end
    local ok, result = pcall(fs.isDirectory, path)
    return ok and result == true
end

-- Resolve an existing path through VFS aliases. For a new leaf, resolve the
-- nearest existing parent and append the missing components to its real path.
function fileops.canonicalCandidate(path)
    local candidate = fs.resolve(path)
    if not candidate then return nil end

    local suffix = {}
    local current = candidate
    while current do
        local ok, attrs = pcall(fs.attributes, current)
        if ok and attrs then
            local real = fs.realPath(current) or current
            for i = #suffix, 1, -1 do
                real = fs.concat(real, suffix[i])
            end
            return real
        end
        if current == "/" then break end
        local name = fileops.basename(current)
        if not name then break end
        table.insert(suffix, name)
        local parent = fs.path(current)
        current = fs.resolve(parent == "" and "." or parent)
    end
    return candidate
end

function fileops.isSameOrDescendant(path, root)
    if path == root then return true end
    if root == "/" then return path:sub(1, 1) == "/" end
    return path:sub(1, #root + 1) == root .. "/"
end

return fileops
