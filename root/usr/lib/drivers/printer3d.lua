-- printer3d.lua - OpenComputers 3D printer driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Sample driver. Each 3D printer gets /dev/printerN (0660 root:lp).
-- Users in group lp open it with device.open:
--
--   local p = device.open("/dev/printer0", "w")
--   p.print({ label = "Cube", shapes = { { 0, 0, 0, 16, 16, 16, texture = "planks_oak" } } }, 1)
--   device.close(p)
--
-- The raw component methods are exposed one to one, plus print(model,
-- count), which loads a whole .3dm model and starts the job.

local driver = {}

driver.info = {
    match = { "printer3d" },
    class = "generic",
    desc = "3D printer (OpenComputers)",
    node = "printer",
    mode = 660,
    group = "lp",
    access = {
        -- reading the printer's state
        status = "r", getShapeCount = "r", getMaxShapeCount = "r",
        getLabel = "r", getTooltip = "r", isButtonMode = "r",
        isRedstoneEmitter = "r", getLightLevel = "r", isCollidable = "r",
        jobs = "r",
        -- changing the model or printing
        reset = "w", setLabel = "w", setTooltip = "w", setButtonMode = "w",
        setRedstoneEmitter = "w", setLightLevel = "w", setCollidable = "w",
        addShape = "w", commit = "w", print = "w",
    },
}

function driver.attach(dev)
    local inst = { dev = dev, proxy = dev.proxy, jobs = 0 }
    log("printer " .. dev.address:sub(1, 8) .. " ready, max "
        .. tostring(dev.proxy.getMaxShapeCount()) .. " shapes")
    return inst
end

function driver.detach(inst)
    inst.proxy = nil
end

driver.ops = {}

-- Methods passed straight to the component. Older OC versions lack the
-- light level and collision methods; those calls report "not supported".
local PASSTHROUGH = {
    "status", "getShapeCount", "getMaxShapeCount", "getLabel", "getTooltip",
    "isButtonMode", "isRedstoneEmitter", "getLightLevel", "isCollidable",
    "reset", "setLabel", "setTooltip", "setButtonMode", "setRedstoneEmitter",
    "setLightLevel", "setCollidable", "addShape",
}
for _, name in ipairs(PASSTHROUGH) do
    driver.ops[name] = function(inst, ...)
        local method = inst.proxy[name]
        if not method then return nil, "not supported" end
        return method(...)
    end
end

local function startJob(inst, count)
    local ok, err = inst.proxy.commit(count)
    if not ok then return nil, err or "printer is busy" end
    inst.jobs = inst.jobs + 1
    inst.dev.emit("printer_job", count)
    return true
end

function driver.ops.commit(inst, count)
    return startJob(inst, count or 1)
end

-- Number of jobs started through this driver since the printer attached.
function driver.ops.jobs(inst)
    return inst.jobs
end

-- Loads a model in the .3dm table format and commits `count` copies.
-- model = { label, tooltip, buttonMode, emitRedstone, lightLevel,
--           collidable = { off, on }, shapes = { { x1, y1, z1, x2, y2, z2,
--           texture = "...", state = bool, tint = n }, ... } }
function driver.ops.print(inst, model, count)
    if type(model) ~= "table" or type(model.shapes) ~= "table" then
        return nil, "model has no shapes"
    end
    count = count or 1
    if type(count) ~= "number" or count < 1 or count % 1 ~= 0 then
        return nil, "invalid count"
    end
    local p = inst.proxy
    local state = p.status()
    if state ~= "idle" then return nil, "printer is busy" end

    p.reset()
    if model.label then p.setLabel(tostring(model.label)) end
    if model.tooltip then p.setTooltip(tostring(model.tooltip)) end
    if model.buttonMode ~= nil then p.setButtonMode(model.buttonMode and true or false) end
    if model.emitRedstone ~= nil then p.setRedstoneEmitter(model.emitRedstone) end
    if model.lightLevel and p.setLightLevel then p.setLightLevel(model.lightLevel) end
    if type(model.collidable) == "table" and p.setCollidable then
        p.setCollidable(model.collidable[1] ~= false, model.collidable[2] ~= false)
    end

    local max = p.getMaxShapeCount()
    if #model.shapes > max * 2 then
        return nil, "too many shapes (" .. #model.shapes .. ", max " .. max .. " per state)"
    end
    for i, s in ipairs(model.shapes) do
        if type(s) ~= "table" or #s < 6 then
            return nil, "shape " .. i .. " is not { x1, y1, z1, x2, y2, z2, texture = ... }"
        end
        local ok, err = p.addShape(s[1], s[2], s[3], s[4], s[5], s[6],
            s.texture or "", s.state and true or false, s.tint)
        if not ok then
            return nil, "shape " .. i .. ": " .. tostring(err)
        end
    end
    return startJob(inst, count)
end

return driver
