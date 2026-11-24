---@class nexus_config
local config = {
    -- Kernel
    kernel_panic_bsod = false;
    kernel_version = {
        id = "Nexus 0.0.6-oc";
        name = "Nexus";
        ver = "0.0.6-oc";
        dist = "Nexus";
    };
    -- Console
    console_force_framebuffer = false;
    console_framebuffer_minimumres = false;
    -- after boot, printk only reaches the console at this level or worse
    -- (emerg alert crit err warning notice info debug, or 0..7); dmesg has all
    console_loglevel = "err";
    -- held keys: seconds before repeating, then repeats per second
    key_repeat_delay = 0.35;
    key_repeat_rate = 30;
    -- Filesystem
    filesystem_read_bytes = math.huge;
}

return config