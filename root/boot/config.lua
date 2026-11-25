---@class nexus_config
local config = {
    -- Development builds (kdebug.lua, the debug module and the
    -- debug-account service; release builds leave them out):
    -- console output of kdebug.print, the DEBUG label, the debug account
    debug = true;
    -- Kernel
    kernel_panic_bsod = false;
    kernel_version = {
        id = "Nexus 0.0.7-dev-oc";
        name = "Nexus";
        ver = "0.0.7-dev-oc";
        dist = "Nexus";
    };
    -- Console
    console_force_framebuffer = false;
    console_framebuffer_minimumres = false;
    -- the vt's state on the top row (debug module)
    console_vt_debug = false;
    -- after boot, printk only reaches the console at this level or worse
    -- (emerg alert crit err warning notice info debug, or 0..7); dmesg has all
    console_loglevel = "err";
    -- held keys: seconds before repeating, then repeats per second
    key_repeat_delay = 0.35;
    key_repeat_rate = 30;
    -- log every key signal and input token to dmesg (debug), with uptime
    -- (debug module)
    tty_debug = false;
    -- every 2s of activity, log kernel loop statistics to dmesg (kdebug.lua)
    loop_stats = false;
    -- Debug consoles, output only: every kernel log line (printk, system.log,
    -- panics) also goes to the Ocelot card's log (ocelot), a serial port of
    -- tools/headless (serial) and a TCP server through an internet card
    -- (tcp = "host:port", tools/debugserver). Lines below level are left out.
    debug_console = {
        ocelot = true;
        serial = true;
        tcp = nil;
        level = "debug";
    };
    -- Filesystem
    filesystem_read_bytes = math.huge;
}

return config