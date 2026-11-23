---@class nexus_config
local config = {
    -- General
    debug = true;
    -- Kernel
    kernel_panic_bsod = false;
    kernel_version = {
        id = "Nexus 0.0.3-dev-oc";
        name = "Nexus";
        ver = "0.0.3-dev-oc";
        dist = "Nexus";
    };
    -- Console
    console_force_framebuffer = false;
    console_framebuffer_minimumres = false;
    console_vt_debug = false;
    -- Filesystem
    filesystem_read_bytes = math.huge;
}

return config