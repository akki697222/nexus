![good logo](https://github.com/akki697222/nexus/blob/main/logo.png?raw=true)
Nexus is a Unix-like monolithic kernel, work perfectry on OpenComputers.

## Features
- Module System
- Permission System
- User/Group System
- BSD-Like vnode based VFS

And the APIs to access other Nexus-specific features (users and permissions) are as follows:
- Module API
- Permission API
- Process API (Extends OpenOS's Process API, allowing access to more advanced functions)
- Extended Filesystem API

Nexus runs on just the kernel, so unlike other systems it is more compact and makes it easier to implement your own OS.

## Attention
- Don't modify `kernel.lua`, this is a concateneted all file of `src` directory, if run build, then `kernel.lua` overwritten by `build.lua`, so your edit has been removed. if you contribute this project, you should edit lua file in `src`