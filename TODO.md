# VFS Issues (Pre-existing)

- [ ] `vfs.mount` calls `vfs.lookupFilesystem`, which recursively scans the entire disk into memory. This causes memory overflow on large filesystems.
- [ ] `vfs.chmod` (and other operations) triggered during boot causing full disk-wide metadata saves repeatedly (O(N^2) boot sequence).
- [x] Inefficient string concatenation (`s = s .. chunk`) in `loadfile`, `readAll`, and `writeMeta` causes excessive memory allocation and GC pressure. (Fixed in `loadfile`)
- [ ] Lack of yielding during recursive VFS scans and metadata saving leading to system freezes or instruction limit errors.

# Fixed Critical Bugs (Startup Crash)

- [x] **Bug #1: Signal Storm** - Removed the `process_resume` signal feedback loop. The scheduler now handles ready tasks internally.
- [x] **Bug #2: Event Queue Leak** - Added `event.removeQueue(pid)` called from `process.kill(pid)` to clean up memory.
- [x] **Bug #3: Module Cache Corruption** - Fixed `require` overwriting `package.loaded` instead of assigning a key.
- [x] **Bug #4: Double Resume** - Redesigned `process.resume` to perform exactly one resume per tick and manage `waiting` status correctly.
