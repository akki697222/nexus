# Nexus installer

Installed systems boot from a single image, `/boot/nexusos` (NXIMG), in the
spirit of a vmlinuz with an embedded rootfs:

| section  | used as                                                     |
| -------- | ----------------------------------------------------------- |
| `kernel` | streamed into `load()` by `/init.lua`, block by block       |
| `usr`    | mounted read-only at `/usr` by the kernel (imgfs)           |
| `etc`    | copied to `/etc` on first boot; existing files are kept     |

Blocks hold 16 KiB of uncompressed data each and, in compressed images, are
standalone zlib streams that an OpenComputers data card inflates directly
(`data.inflate`). Without a data card, `/init.lua` inflates them in Lua and
hands the same inflater to the kernel for `/usr`. Modes and owners of `/usr` come from the image, so they
cannot be changed on disk (including the set-user-ID bit of `sudo`).

## Building

From the repository root (Lua 5.3+):

```sh
lua tools/nximg.lua dist build           # build/nexusos, build/init.lua, build/config.lua
lua tools/nximg.lua dist build --store   # uncompressed image (about 4x larger)
lua tools/nximg.lua info build/nexusos [usr|etc]
lua tools/nximg.lua verify build/nexusos
```

`init.lua` is `bootstrap/init.lua` and `config.lua` is `root/boot/config.lua`.
Compression on the host uses `tools/lib/libdeflate.lua`; nothing on the
target needs LibDeflate.

## Installing from OpenOS

1. Copy `installer/nexus-install.lua` to the OpenOS machine.
2. Serve the `dist` directory over HTTP(S), or put it on a local disk.
3. Run:

```sh
nexus-install http://example.test/nexus <address|label> [reboot]
nexus-install /mnt/abc/nexus <address|label> [reboot]
```

Without a target, the command lists filesystems with address, label and free
space. The installer copies the three files as they are (no decompression,
memory bounded by one chunk), checks the image header, index checksums and
size while streaming, writes each file to `<name>.new` and renames it into
place. An existing `/boot/config.lua` is kept. It labels the target `Nexus`,
sets it as the boot device, and reboots when `reboot` is given. The running
boot disk is refused unless `--force` is passed.

## Requirements

- Compressed images boot faster with a data card (tier 1 or higher), which
  inflates blocks natively; without one they are inflated in Lua, which is
  slower and uses more CPU time on every `/usr` read. `--store` images
  (about 4x larger) need no inflating at all.
- Development setups keep booting `root/init.lua`, which loads a plain
  `/boot/kernel.lua` and uses the on-disk `/usr`.
