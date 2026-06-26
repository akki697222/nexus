local package = {}
package.config = "/\n;\n?\n!\n-\n"
package.path =
"/lib/?.lua;/usr/lib/?.lua;/home/lib/?.lua;./?.lua;/lib/?/init.lua;/usr/lib/?/init.lua;/home/lib/?/init.lua;./?/init.lua"                --openos default
-- fallback
package.cpath = package.path
package.loaded = {}
package.preload = {}

function package.searchpath(name, path, sep, rep)
    local dirsep, pathsep, placeholder, execdir, opensep = package.config:match(
        "([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)")
    dirsep = rep or dirsep
    name = name:gsub("%" .. (sep or "."), dirsep)
    local index = 0
    local err
    repeat
        local term, next = path:find(pathsep, index + 1, true)
        local filename = term and path:sub(index + 1, term - 1) or path:sub(index + 1)
        filename = filename:gsub(placeholder, name)
        if vfs.exists(filename) then
            return filename
        end
        err = string.format("%s\n\tno file '%s'", err or "", filename)
        index = next
    until term == nil
    return nil, err
end

function package.loadlib(libname, funcname)
    error("C module loading not supported")
end

local function searcher_lua(modname)
    local filepath, err = package.searchpath(modname, package.path)
    if not filepath then
        return nil, err
    end
    local chunk, load_err = loadfile(filepath)
    if not chunk then
        return nil, load_err
    end
    return chunk, filepath
end

local function searcher_preload(modname)
    local loader = package.preload[modname]
    if loader then
        return loader, ":preload:"
    else
        return nil, "\n\tno field package.preload['" .. modname .. "']"
    end
end

package.searchers = {
    searcher_preload,
    searcher_lua,
}

function require(modname)
    assert(type(modname) == "string", "bad argument #1 to 'require' (string expected)")

    if package.loaded[modname] ~= nil then
        return package.loaded[modname]
    end

    local errors = {}

    for _, searcher in ipairs(package.searchers) do
        local loader, param = searcher(modname)
        if type(loader) == "function" then
            local result = loader(modname, param)
            if result ~= nil then
                package.loaded[modname] = result
            else
                package.loaded[modname] = true
            end
            return package.loaded[modname]
        elseif loader and param == ":preload:" then
            package.loaded[modname] = loader
            return loader
        else
            table.insert(errors, param or loader or "unknown error")
        end
    end

    error("module '" .. modname .. "' not found:" .. table.concat(errors), 2)
end
