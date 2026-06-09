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

### Core Modules (`src/` directory)
- **base.lua** - Core runtime environment and logging
- **main.lua** - Kernel entry point and initialization
- **vfs.lua** - Virtual filesystem with vnode implementation
- **devfs.lua** - Device filesystem for hardware access
- **device.lua** - Device abstraction and management
- **module.lua** - Module loading and lifecycle management
- **process.lua** - Process/task management and scheduling
- **thread.lua** - Coroutine-based threading
- **event.lua** - Event bus and handler system
- **io.lua** - Input/output operations
- **fbcon.lua** - Framebuffer console for graphics output
- **os.lua** - OS-level utilities and functions
- **system.lua** - System information and configuration
- **package.lua** - Lua package/module loader integration
- **permission.lua** - Permission checking and enforcement
- **user.lua** - User account management
- **group.lua** - Group management
- **procfs.lua** - Process filesystem (virtual proc directory)
- **util.lua** - Utility functions
- **sha2.lua** - SHA-2 cryptographic hashing

## Building

The kernel is built from source files in `src/` using `build.lua`. This generates `build/kernel.lua`, which contains the concatenated kernel code.

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