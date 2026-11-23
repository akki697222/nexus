-- klog: the kernel log ring buffer behind printk, system.log and dmesg.
-- Entries carry a sequence number so readers (syslogd) can ask for what is
-- new since their last read and notice when entries were dropped.

---@class klog_entry
---@field seq integer
---@field uptime number
---@field time integer real time, Unix seconds
---@field level string
---@field tag string
---@field pid integer|nil
---@field uid integer|nil
---@field msg string

klog = {}

klog.LEVELS = { emerg = 0, alert = 1, crit = 2, err = 3, warning = 4, notice = 5, info = 6, debug = 7 }
-- Bounded by bytes as well as entries: RAM is scarce on OpenComputers.
klog.MAX_ENTRIES = 256
klog.MAX_BYTES = 16384
klog.MAX_MESSAGE = 256

local ring = {}
local first, nextSeq, bytes = 1, 1, 0

---@param level string
---@param tag string
---@param msg string
---@param pid? integer
---@param uid? integer
function klog.record(level, tag, msg, pid, uid)
    msg = tostring(msg):gsub("[%c]", " ")
    if #msg > klog.MAX_MESSAGE then msg = msg:sub(1, klog.MAX_MESSAGE) end
    local entry = {
        seq = nextSeq, uptime = computer.uptime(), time = getRealTime(),
        level = level, tag = tag, pid = pid, uid = uid, msg = msg,
    }
    ring[nextSeq] = entry
    nextSeq = nextSeq + 1
    bytes = bytes + #msg + #tag + 32
    while first < nextSeq - 1 and (nextSeq - first > klog.MAX_ENTRIES or bytes > klog.MAX_BYTES) do
        local old = ring[first]
        bytes = bytes - (#old.msg + #old.tag + 32)
        ring[first] = nil
        first = first + 1
    end
end

-- Copies of the entries newer than `since`, the newest sequence number,
-- and the oldest one still held (a reader whose `since` is below it lost
-- the entries in between).
---@param since? integer
---@return klog_entry[] entries, integer newest, integer oldest
function klog.read(since)
    since = math.max(tonumber(since) or 0, first - 1)
    local out = {}
    for seq = since + 1, nextSeq - 1 do
        local e = ring[seq]
        if e then
            out[#out + 1] = { seq = e.seq, uptime = e.uptime, time = e.time, level = e.level,
                tag = e.tag, pid = e.pid, uid = e.uid, msg = e.msg }
        end
    end
    return out, nextSeq - 1, first
end
