-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- module_service: require() with one cache shared by every process
-- (per-process caches would not fit OC's RAM).

local SEARCH = {
    "System://Library/?.lua",
    "System://Library/?/init.lua",
}

local LOADING = {}   -- sentinel for cyclic require detection

module = {}
module.loaded = {}
module.search = SEARCH

function module.require(name)
    arg(1, name, "string")
    local cached = module.loaded[name]
    if cached == LOADING then
        error("cyclic require of '" .. name .. "'", 2)
    end
    if cached ~= nil then return cached end

    local rel = name:gsub("%.", "/")
    local tried = {}
    for _, tpl in ipairs(module.search) do
        local path = tpl:gsub("%?", rel)
        local src = fs.read_file(path)
        if src then
            local fn, err = load(src, "@" .. path, "t", _ENV)
            if not fn then
                error("error loading module '" .. name .. "': " .. tostring(err), 2)
            end
            module.loaded[name] = LOADING
            local ok, res = pcall(fn, name, path)
            if not ok then
                module.loaded[name] = nil
                error("error in module '" .. name .. "': " .. tostring(res), 2)
            end
            if res == nil then res = true end
            module.loaded[name] = res
            log.debug("[module] loaded '%s' from %s", name, path)
            return res
        end
        tried[#tried + 1] = "\n\tno file '" .. path .. "'"
    end
    error("module '" .. name .. "' not found:" .. table.concat(tried), 2)
end

function module.invalidate(name)
    module.loaded[name] = nil
end

require = module.require

log.info("[module] ready")
service_manager.ready("module")
while true do
    event.pull()
end
