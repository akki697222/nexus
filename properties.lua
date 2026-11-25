local properties = {}

-- build settings
properties.buildDir = "build"
properties.buildOutput = "kernel.lua"
properties.buildVersion = "0.0.7"
-- include settings
properties.includeDir = "src"
-- the names sources share; joined first and as it is (tools/kbuild.lua)
properties.prelude = "prelude.lua"
-- each joined in a do ... end block of its own, in this order
properties.includes = {
    -- kernel/: boot, logging and console, system calls, environments
    -- lib/: helpers; sec/: users, groups, permissions, policy
    -- fs/: the VFS and filesystems; proc/: processes, threads, events,
    -- modules; dev/: devices and drivers; api/: io, os, package for userland
    "kernel/base.lua",
    "lib/sha2.lua",
    "lib/util.lua",
    "kernel/klog.lua",
    "kernel/debugcon.lua",
    "kernel/fbcon.lua",
    "sec/permission.lua",
    "sec/user.lua",
    "fs/vfs/vnode.lua",
    "fs/vfs/fd.lua",
    "fs/vfs/path.lua",
    "fs/vfs/mount.lua",
    "fs/vfs/ops.lua",
    "fs/vfs/meta.lua",
    "fs/vfs/io.lua",
    "fs/devfs.lua",
    "fs/procfs.lua",
    "fs/imgfs.lua",
    "api/package.lua",
    "proc/process/queue.lua",
    "proc/process/spawn.lua",
    "proc/process/signal.lua",
    "proc/process/block.lua",
    "proc/process/run.lua",
    "proc/thread.lua",
    "sec/group.lua",
    "proc/module.lua",
    "proc/event.lua",
    "dev/device.lua",
    "api/io.lua",
    "api/os.lua",
    "kernel/system.lua",
    "sec/policy.lua",
    "dev/devmgr.lua",
    "kernel/env.lua",
    -- development builds only; release branches drop this line
    "kernel/kdebug.lua",
    "kernel/main.lua",
}
properties.overwrite = true
properties.minify = false
return properties
