-- installer/groups.lua - optional parts of the root filesystem
--
-- Read by `lua tools/nximg.lua dist` for manifest.lua. Every file of the
-- rootfs belongs to the base system unless a group below lists it; paths
-- are relative to / (usr/..., etc/...). A group whose files are all
-- missing (release branches drop the debug files) is left out.
-- Each driver in usr/lib/modules/modules.idx becomes a group "driver:<name>" of its own.
--
--   modules: kernel module names of the group, as listed in /etc/modules.lua
--   default: selected unless the user deselects it
return {
    {
        id = "debug",
        name = "Debug tools",
        desc = "debug kernel module and debug account (development builds)",
        default = true,
        paths = {
            "usr/lib/modules/system/kernel/debug.lua",
            "usr/sbin/debug-account.lua",
            "etc/init.d/debug-account",
            "etc/runlevels/default/debug-account",
        },
        modules = { "debug" },
    },
}
