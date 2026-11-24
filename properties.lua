local properties = {}

-- build settings
properties.buildDir = "build"
properties.buildOutput = "kernel.lua"
properties.buildVersion = "0.0.3"
-- include settings
properties.includeDir = "src"
properties.includes = {
    "base.lua",
    "sha2.lua",
    "util.lua",
    "klog.lua",
    "fbcon.lua",
    "permission.lua",
    "user.lua",
    "vfs.lua",
    "devfs.lua",
    "procfs.lua",
    "imgfs.lua",
    "package.lua",
    "process.lua",
    "thread.lua",
    "group.lua",
    "module.lua",
    "event.lua",
    "device.lua",
    "io.lua",
    "os.lua",
    "system.lua",
    "policy.lua",
    "devmgr.lua",
    "env.lua",
    "main.lua",
}
properties.overwrite = true
properties.minify = false
return properties
