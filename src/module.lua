---@class module
module = {}

---@type table<string, kernel_module>
local kmodule_loaded = {}

function module.autoload()
    local f, err = loadfile("/etc/modules.lua", "bt", util.createEnv())
    if not f then
        printk("module: autoload: " .. (err or "no /etc/modules.lua found"))
        return
    end

    local s, modules = xpcall(f, debug.traceback)
    if not s or type(modules) ~= "table" then
        printk("module: autoload: invalid format /etc/modules.lua")
        return
    end

    for _, path in ipairs(modules) do
        local m, e = module.load(path)
        if not m then
            printk("module: autoload: failed to load '" .. path .. "': " .. e)
        end
    end
end

---@return kernel_module|nil, string|nil # error
function module.load(path)
    local f, err = loadfile(vfs.resolve(path), "bt", util.createEnv())

    if not f then
        return nil, err or "Unknown Error"
    end

    local s, err = xpcall(f, debug.traceback)
    if not s then
        return nil, err
    elseif type(err) == "table" then
        ---@type kernel_module
        local mod = err
        if type(mod.load) ~= "function"
            or type(mod.unload) ~= "function"
            or type(mod.module) ~= "table"
            or type(mod.manifest) ~= "table" then
            return nil, "Invalid or not a module"
        end

        local man = mod.manifest
        if type(man.name) ~= "string"
            or type(man.desc) ~= "string"
            or type(man.version_n) ~= "number" then
            return nil, "Invalid module manifest"
        end

        -- dependencies are currently not available
        -- TODO: add load depended modules

        s, err = xpcall(mod.load, debug.traceback)
        if not s then
            return nil, err
        end

        if kmodule_loaded[man.name] then
            return nil, "Module duplicated or already loaded"
        else
            kmodule_loaded[man.name] = mod
        end

        return mod
    else
        return nil, "Invalid module"
    end
end

---@return string|nil
function module.unload(name)
    ---@type kernel_module|nil
    local mod = kmodule_loaded[name]
    if mod then
        local s, err = xpcall(mod.unload, debug.traceback)
        if not s then
            printk("module: unsafe module unloading occurred on unloading module '" .. name .. "'")
            printk("module: " .. err)
            return "Unknown error"
        else
            kmodule_loaded[name] = nil
        end
    else
        return "Unknown module"
    end
end

---@return table|nil
function module.require(name)
    local mod = kmodule_loaded[name]
    return mod and mod.module or nil
end

---@return kernel_module|nil
function module.get(name)
    return kmodule_loaded[name]
end

function module.exists(name)
    return kmodule_loaded[name] ~= nil
end
