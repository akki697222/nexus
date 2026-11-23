local properties = {}

-- build settings
properties.buildDir = "build"
properties.buildOutput = "kernel.lua"
properties.buildVersion = "0.1.1"
-- include settings
properties.includeDir = "src"
properties.includes = {
    "base.lua",
    "sha2.lua",
    "util.lua",
    "fbcon.lua",
    "permission.lua",
    "user.lua",
    "vfs.lua",
    "devfs.lua",
    "procfs.lua",
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
    "driver.lua",
    "env.lua",
    "main.lua",
}
properties.overwrite = true
properties.minify = false
-- gzip-compress the kernel image (requires LibDeflate in root/usr/lib)
properties.compress = false
return properties
