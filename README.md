![good logo](logo.png)

# Nexus

A Unix-like monolithic kernel that works perfectly on OpenComputers. Nexus provides a compact, modular kernel environment designed to make it easier to implement custom operating systems without unnecessary bloat.

## Features

### Core Systems
- **Module System** - Dynamic module loading and management
- **Permission System** - Fine-grained access control based on user/group permissions
- **User/Group System** - Complete user and group management with ownership tracking
- **BSD-Like vnode-based VFS** - Virtual filesystem supporting multiple device mounts

### Advanced APIs
- **Module API** - Load and manage kernel modules dynamically
- **Permission API** - Set and check file/resource permissions
- **Process API** - Extended process management (builds on OpenOS's Process API with advanced functions)
- **Extended Filesystem API** - Full filesystem operations with permission and ownership support
- **Device API** - Direct device component management
- **Event System** - Kernel event handling and routing

## Architecture

Nexus is organized as a monolithic kernel with clear separation of concerns:

### Kernel sources (`src/`)

`properties.lua` lists the sources in build order. `tools/kbuild.lua` joins
them into `build/kernel.lua`: `src/prelude.lua` first (the names sources
share), then every source in a `do ... end` block of its own.

- **`kernel/`** - boot and entry point (`base.lua`, `main.lua`), kernel log
  (`klog.lua`), console (`fbcon.lua`), debug consoles (`debugcon.lua`),
  system calls (`system.lua`), process environments (`env.lua`)
- **`lib/`** - utilities (`util.lua`), SHA-2 (`sha2.lua`)
- **`sec/`** - permissions, users, groups, the access policy
- **`fs/`** - the virtual filesystem (`vfs/`: vnodes, descriptors, paths,
  mounts, operations, metadata, pipes and I/O) and devfs, procfs, imgfs
- **`proc/`** - processes (`process/`: queues, spawn, signals, blocking, the
  scheduler pass), threads, events, kernel modules
- **`dev/`** - devices and the driver manager
- **`api/`** - `io`, `os` and `package` as userland sees them

## Building

`lua tools/kbuild.lua` (any OS, Lua 5.3+) writes `build/kernel.lua`;
`build.bat` does that and deploys to the test disks. Tests:
`lua tests/run.lua`.

## Important Notes

### Development Workflow
- **Never edit `build/kernel.lua`** directly - this file is auto-generated
- **Always edit files in `src/` directory** - your changes will be lost if you modify the kernel file
- Run the build process to regenerate `kernel.lua` from `src/` files

### Compactness
Unlike other operating systems, Nexus runs on just the kernel without requiring a bloated system layer. This makes it:
- Lightweight and efficient
- Easier to customize and extend
- Ideal for embedded or resource-constrained environments
- Simple to understand and modify