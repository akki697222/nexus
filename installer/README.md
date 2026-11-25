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

With an internet card, one command downloads the installer from the GitHub
release and installs Nexus onto the boot disk, the disk OpenOS is running
from:

```sh
wget -f https://github.com/akki697222/nexus/releases/download/v0.0.6/nexus-install.lua /tmp/nexus-install.lua && /tmp/nexus-install.lua
```

**A clean install erases the whole target disk**, OpenOS and `/home`
included. The installer prints a warning and asks for `yes` first; the
computer reboots into Nexus afterwards.

```sh
nexus-install [<address|label>] [-y] [--upgrade] [--from <url|dir>] [--reboot]
```

| option | effect |
| --- | --- |
| `<address\|label>` | install to another disk instead of the boot disk |
| `-y` | skip the confirmation |
| `--upgrade` | replace only `/boot/nexusos` and `/init.lua`; keep the rest of the disk and an existing `/boot/config.lua` |
| `--from <url\|dir>` | take the distribution from another URL prefix or a local directory (default: the release the installer belongs to) |
| `--reboot` | reboot after installing to another disk (the boot disk always reboots) |
| `--help` | list the disks, the boot disk marked `*` |

All three files are downloaded and checked (image header, index checksums
and size) before anything is erased: into `/.nexus-install` on the target,
or into memory when the target has less than 320 KB free. A failed download
leaves the disk as it was. Files are copied as they are, so no data card is
needed. The target is labelled `Nexus` and set as the boot device.

## Requirements

- Compressed images boot faster with a data card (tier 1 or higher), which
  inflates blocks natively; without one they are inflated in Lua, which is
  slower and uses more CPU time on every `/usr` read. `--store` images
  (about 4x larger) need no inflating at all.
- Development setups keep booting `root/init.lua`, which loads a plain
  `/boot/kernel.lua` and uses the on-disk `/usr`.
