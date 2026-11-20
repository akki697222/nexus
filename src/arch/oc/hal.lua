-- Bare-metal OpenComputers backend. Loaded before the common kernel sources.
local ocComputer = computer
local hal = {
    platform = "OpenComputers",
    uptime = ocComputer.uptime,
    pullEvent = ocComputer.pullSignal,
    shutdown = ocComputer.shutdown,
}
