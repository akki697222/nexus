local vfs
local runProcessQueue = function(event)end
local resumeKernelThreads = function()end

---@class fbcon : console_device
local fbcon = {
    gpu = nil,
    width = 0,
    height = 0,
    cx = 1,
    cy = 1,
    buffer = {},
    fg = 0xFFFFFF,
    bg = 0x000000,
    lf = false
}

function fbcon.reset()
    local gpu = component.proxy(component.list("gpu")())
    if not gpu then
        error("No GPU found")
    end
    fbcon.gpu = gpu
    gpu.freeAllBuffers()
    fbcon.width, fbcon.height = gpu.maxResolution()
    gpu.setResolution(fbcon.width, fbcon.height)
    gpu.setViewport(fbcon.width, fbcon.height)
    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, fbcon.width, fbcon.height, " ")
    fbcon.cx = 1
    fbcon.cy = 1
end

function fbcon.scroll(i)
    if not fbcon.gpu then return end
    i = i or 1
    if i >= fbcon.height then
        fbcon.gpu.fill(1, 1, fbcon.width, fbcon.height, " ")
        fbcon.cy = fbcon.height
        return
    end
    fbcon.gpu.copy(1, 1 + i, fbcon.width, fbcon.height - i, 0, -i)
    fbcon.gpu.fill(1, fbcon.height - i + 1, fbcon.width, i, " ")
    fbcon.cy = fbcon.height
end

function fbcon.write(text)
    local gpu = fbcon.gpu
    if not gpu then return end

    text = tostring(text or "")
    local len = #text
    local final = ""
    local i = 1

    while i <= len do
        local c = text:sub(i, i)

        if c == "\27" then
            local j = i + 1
            if j <= len and text:sub(j, j) == "[" then
                j = j + 1
                while j <= len do
                    local nc = text:sub(j, j)
                    if nc:match("[%@A-Za-z]") then
                        i = j
                        break
                    end
                    j = j + 1
                end
            end
        elseif c == "\r" then
            fbcon.cx = 1
        elseif c == "\n" then
            if not fbcon.lf then fbcon.cx = 1 end
            fbcon.cy = fbcon.cy + 1
        elseif c == "\t" then
            fbcon.cx = fbcon.cx + (4 - (fbcon.cx - 1) % 4)
        else
            if fbcon.cx > fbcon.width then
                fbcon.cx = 1
                fbcon.cy = fbcon.cy + 1
            end

            if fbcon.cy > fbcon.height then
                fbcon.scroll()
            end
            
            final = final .. c
            gpu.set(fbcon.cx, fbcon.cy, c)
            fbcon.cx = fbcon.cx + 1
        end
        i = i + 1
    end
    if fbcon.buffer then
        table.insert(fbcon.buffer, final)
    end
end

function fbcon.getSize()
    return fbcon.width, fbcon.height
end

write = function(...)
    local proc = process.getCurrent()
    if proc ~= nil then
        local stdout = proc.fd[2].fd
        vfs.write(stdout, ...)
    else
        vfs.write(1, ...)
    end
end

print = function(...)
    local args = { ... }
    local str = ""
    for i, v in ipairs(args) do
        str = str .. tostring(v) .. (i == #args and "" or "\t")
    end
    write(str .. "\n")
end

printd = function(...)
    if config.debug then
        print(...)
    end
end

printk = function(...)
    write(string.format("[%8.2f] %s\n", computer.uptime(), tostring(... or "")))
end

panic = function(err, reason)
    if config.bsod then
        local gpu = component.proxy(component.list("gpu")()) --[[@as oc_component_gpu]]
        local w, h = gpu.getResolution()
        gpu.setForeground(0xFFFFFF)
        gpu.setBackground(0x0000FF)
        gpu.fill(1, 1, w, h, " ")
        gpu.set(1, 1, ":(")
        gpu.set(1, 2, "Kernel panic - " .. err .. ": " .. reason)
        for _ = 0, 2 do
            computer.beep()
        end
        while true do
            computer.pullSignal()
        end
    else
        local header = "Kernel panic - " .. err .. ": " .. reason
        printk(header)
        printk("PID: " .. tostring(process.current) .. " " .. _OSVERSIONSTRING)
        printk("Hardware name: " .. _MACHINE)
        printk("Call Trace:")
        local trace = debug.traceback("", 2)
        local first = true
        for line in string.gmatch(trace, "([^\r\n]+)") do
            if not first then
                printk("  " .. string.match(line, "^%s*(.*)"))
            end
            first = false
        end
        for _ = 0, 2 do
            computer.beep()
        end
        -- resume kthreads and processes once to force update screen
        runProcessQueue({})
        resumeKernelThreads()
        while true do
            computer.pullSignal()
        end
    end
end
