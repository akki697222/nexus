-- printk levels: everything reaches klog; after boot only messages at or
-- above config.console_loglevel reach the console.
-- Run from the Nexus directory: lua tests/printk_level.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("a")
    f:close()
    return s
end

local console = {}
local env = setmetatable({
    computer = { uptime = function() return 1.5 end },
    getRealTime = function() return 1800000000 end,
    vfs = { write = function(_, s) console[#console + 1] = s end },
    config = {},
}, { __index = _G })

local source = read("src/klog.lua") .. "\n"
    .. read("src/fbcon.lua"):gsub("^local vfs\n", "local vfs = _ENV.vfs\n", 1)
    .. "\nreturn fbcon, klog"
local fbcon, klog = assert(load(source, "=printk", "t", env))()

local function levelsOf(seqFrom)
    local out = {}
    for _, e in ipairs(klog.read(seqFrom)) do out[#out + 1] = e.level .. ":" .. e.msg end
    return table.concat(out, "|")
end

-- during boot everything is shown
env.printk("booting")
env.printk("detail", "debug")
assert(#console == 2 and console[1]:find("booting"))

-- after init: default threshold is err
fbcon.booted = true
console = {}
env.printk("chatty")
env.printk("hmm", "warning")
env.printk("broken", "err")
env.printk("dying", "emerg")
assert(#console == 2 and console[1]:find("broken") and console[2]:find("dying"),
    table.concat(console, ""))

-- klog keeps all of them with their levels; unknown levels become info
env.printk("odd", "loud")
local log = levelsOf(0)
assert(log:find("info:booting") and log:find("debug:detail") and log:find("warning:hmm")
    and log:find("err:broken") and log:find("emerg:dying") and log:find("info:odd"), log)

-- the threshold is configurable by name or number
env.config.console_loglevel = "warning"
console = {}
env.printk("hmm2", "warning")
env.printk("quiet", "info")
assert(#console == 1 and console[1]:find("hmm2"))
env.config.console_loglevel = 7
console = {}
env.printk("everything", "debug")
assert(#console == 1)

print("printk level tests passed")
