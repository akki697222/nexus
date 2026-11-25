-- prelude.lua - the names kernel sources share.
--
-- The build joins the sources into one chunk (build/kernel.lua): this file
-- first, as it is, then every other source in a `do ... end` block of its
-- own, so the locals of a source stay its own (a Lua function has room for
-- 200 locals, which the whole kernel would otherwise have to share).
-- What sources share is declared here, as upvalues: kernel-private, never
-- in the global table.

-- The raw OpenComputers APIs. main.lua drops the globals before any userland
-- code runs; only policy.lua uses `component` directly.
local component, computer = component, computer

-- Subsystems one source defines and others use.
local util, permission, fbcon, vfs, vfsk, vhandles, descriptor, devfs, procfs,
    imgfs, package, process, event, module, system, device, io

-- Set by main.lua once the scheduler runs; panic() calls them.
local runProcessQueue, resumeKernelThreads = function() end, function() end
