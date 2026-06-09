---@type log
local log = {}

log.level = {
    info  = 0,
    warn  = 1,
    error = 2,
    debug = 3,
    panic = 4,
}

log.level_names = {
    [0] = "Info",
    [1] = "Warn",
    [2] = "Error",
    [3] = "Debug",
    [4] = "Panic"
}

local gpu = nil
local w, h, cy = -1, -1, 0

function log.init(gpu_, screen_)
    arg(1, gpu_, "table")
    arg(2, screen_, "string")
    gpu = gpu_
    cy = 0
    gpu.bind(screen_, true)
    w, h = gpu.maxResolution()
    gpu.setResolution(w, h)
    gpu.setDepth(gpu.maxDepth())
    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, w, h, " ")
end

function log.kernel_log(level, fmt, ...)
    if not gpu then
        error("logger not initialized", 2)
    end
    local formatted = string.format(fmt, ...)
    formatted = string.format("|%7.2f: [%s] %s", computer.uptime() or -1, log.level_names[level], formatted)
    formatted = formatted:gsub("\t", "    ")
    for text in formatted:gmatch("[^\n]+") do
        while #text > 0 do
            local l = text:sub(1, w)

            text = text:sub(#l + 1)
            cy = cy + 1

            if cy > h then
                gpu.copy(1, 1, w, h, 0, -1)
                gpu.fill(1, 1, w, h, " ")
            end

            gpu.set(1, cy, l)
        end
    end
end

function log.info(fmt, ...)
    log.kernel_log(0, fmt, ...)
end

function log.warn(fmt, ...)
    log.kernel_log(1, fmt, ...)
end

function log.error(fmt, ...)
    log.kernel_log(2, fmt, ...)
end

function log.debug(fmt, ...)
    log.kernel_log(3, fmt, ...)
end

function log.panic(fmt, ...)
    log.kernel_log(4, fmt, ...)
end
