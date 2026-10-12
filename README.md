![good logo](logo.png?raw=true)

# Nexus

A Lua-runtime-native OS for OpenComputers: coroutine processes, capability based
access, event routing, a VFS with drive URIs, and a Wayland-style compositor.
Design notes: `../spec.md`.

## Build and run

```
cd nexus
lua build.lua        # bundles kernel/ -> ocelot/boot/init.lua and deploys everything
```

Then start Ocelot (`ocelot.bat`) and boot the machine from `ocelot/boot`.
The OS writes a log to `ocelot/boot/debug.log` (flushed on errors and every second).
The boot self test (`selftest` command) prints `selftest: N/N passed`.

## Layout

| Source | Deployed to | Purpose |
|---|---|---|
| `kernel/` | `Boot://init.lua` | scheduler, events, processes, capabilities, IPC, service manager, stdio |
| `service/{storage,filesystem,module,driver,terminal}` | `Boot://Services/` | core services the kernel starts |
| `service/{init,compositor,selftest}` | `System://Services/` | semi-user services |
| `Exec/` | `System://Exec/` | commands (`sh`, `ls`, `edit`, `gui`, ...) |
| `Library/` | `System://Library/` | `require()` libraries (`gui`, `lineedit`) |
| `Config/` | `System://Config/` | configuration (`gui.lua`) |

Drive URIs: `Boot://` is the boot disk root (kernel readable without the VFS),
`System://` is `/System` on the boot disk, `Temp://` is the tmpfs, `Data://` further disks.
Directory names are CamelCase; file names are lowercase.

## Shell

`help` lists the commands. Quoting, pipes (`|`), redirects (`>`, `>>`), Tab completion,
history, `Ctrl+C` (interrupt) and `Ctrl+D` (EOF) work. `lua` starts a REPL inside the
kernel environment; `edit <file>` is a small editor (`Ctrl+S` save, `Ctrl+Q` quit).

## GUI

`gui` starts the compositor (`Alt+Shift+E` quits). The modifier is `mod = Alt+Shift`
because plain Alt combinations collide with host / game keys.

| Key | Action |
|---|---|
| `mod+Enter` | terminal |
| `mod+D` | demo window |
| `mod+J` / `mod+K` | focus next / previous |
| `mod+Q` | close |
| `mod+M` | maximize |
| `mod+T` / `mod+F` | tiling / floating |
| `mod+E` | quit |

Windows: drag the title bar to move, drag the bottom-right corner to resize, `[x]` closes.
Terminal scrollback: mouse wheel or `Shift+PgUp` / `Shift+PgDn`.
`guictl list | policy <name|path> | redraw | quit` controls a running compositor.

Customise through `System://Config/gui.lua` (policy, fps, theme, binds, autostart) or
write your own window-management policy as a Lua file (`place`, `arrange`, `key`, `pointer`).
Clients use `require("gui")`; see `Exec/gui-hello.lua` for a complete example.

## Limits worth knowing

- Text is ASCII only for now (cells are one byte wide).
- OC filesystem writes cost about one tick each, so the logger buffers them.
- Everything shares one Lua VM: there is no memory isolation between processes.
