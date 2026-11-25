# Nexus installer

Nexus installs like a Unix system: the kernel is a boot image, and the root
filesystem is unpacked onto the disk as ordinary, writable files.

| on the disk        | what it is                                                     |
| ------------------ | -------------------------------------------------------------- |
| `/init.lua`        | boot loader (`bootstrap/init.lua`)                             |
| `/boot/nexusos`    | kernel image (NXIMG with only a kernel section, zlib by default) |
| `/boot/config.lua` | kernel configuration                                           |
| `/usr`, `/etc`     | the root filesystem as files                                   |
| `.meta` files      | modes and owners (`sudo` is set-user-ID), written by the installer |
| `/home/<user>`     | the account made during the install; root stays locked         |

The installer is one file, `nexus-install.lua`, in two stages:

- **stage0** runs as a program on the OS you have (OpenOS, plan9k, ...). It
  copies itself to the target disk as `/init.lua`, keeps the old `/init.lua`
  in `/.nexus-install/init.lua.orig` and restarts. Nothing is erased.
- **stage1** boots as `/init.lua`, without an OS, so it works the same
  whatever was there before. It asks for the disk, hostname, user, optional
  parts and kernel image format (dialogs in the style of debian-installer;
  a tier 1 screen works too), then erases the disk, unpacks the system and
  finally replaces `/init.lua` with the boot loader. **Cancel** on its first
  screen puts the old `/init.lua` and boot disk back.

## Installing

### From OpenOS (or another OS), online

With an internet card:

```sh
wget -f https://raw.githubusercontent.com/akki697222/nexus/dev-oc/dist/nexus-install.lua /tmp/nexus-install.lua
/tmp/nexus-install.lua
```

The installer takes the release that `dist/channel.lua` on the default
branch (`dev-oc`) names (`stable`), so an older copy still installs the
current release; when the release has a newer installer, it updates itself
first.

The first download comes from `raw.githubusercontent.com` on purpose:
GitHub's release downloads always answer with a redirect, and some internet
cards (OpenComputers Rebooted) and OpenOS's `wget` do not follow redirects,
which leaves an empty file. The installer follows them itself for the
release files.

### Offline

Copy a release directory (`lua tools/nximg.lua dist <dir>`) to the computer
and point the installer at it; the files are copied to the target and the
install needs no internet card:

```sh
/path/to/release/nexus-install.lua --from /path/to/release
```

### From an install medium

`lua tools/nximg.lua media <release dir> <out dir>` makes a disk (a floppy
fits) that boots straight into stage1, with the release on it. Boot it and
install to any disk, itself included. This is also the way for OSes that do
not let programs use components.

### stage0 options

```
nexus-install [<address|label>] [options]
  --from <dir|url>       release directory (offline) or URL
  --answers <file>       answers.lua to start from
  --hostname <name>      --user <name>      --password-hash <hex>
  --groups <all|none|id,...>                --kernel <zlib|store>
  --unattended           install without questions
  -y, --yes              restart without asking
  --no-reboot            prepare only
  --self <file>          this installer's file, if it cannot be found
```

The target is the boot disk unless an address (or its start) or a label is
given. On plan9k, whose shell only runs programs from `PATH`, copy the file
to `/bin` first.

### Unattended installs

stage1 reads `/.nexus-install/answers.lua` (stage0 writes it from the
options). With `unattended = true` nothing is asked:

```lua
return {
    unattended = true,
    hostname = "box",
    user = { name = "alice", hash = "<128 hex digits>" },
    groups = { "driver:internet" },   -- or "all" / "none"; default: the defaults
    kernel = "zlib",                  -- or "store"
    source = "offline",               -- or "online" (base = "<url>" to override)
}
```

`hash` is the `/etc/shadow` form: SHA-512 of the password followed by
`salt`, in hex (`src/sec/user.lua`). Just before erasing, stage1 writes
`confirmed = true` here, so a restart in the middle resumes the install
without asking again.

## Releases

```sh
lua tools/kbuild.lua
lua tools/nximg.lua dist build/dist     # [--store] for uncompressed images
lua tools/nximg.lua media build/dist build/media
```

`dist` writes the release assets:

| file                | |
| ------------------- | --- |
| `nexusos`           | kernel image (kernel section only) |
| `rootfs`            | NXIMG with the `usr` and `etc` sections (files with modes and owners) |
| `init.lua`          | boot loader |
| `config.lua`        | default `/boot/config.lua` |
| `nexus-install.lua` | the installer, joined from `installer/src` by `tools/mkinstaller.lua` |
| `manifest.lua`      | version, installer revision, sizes, CRC-32s, optional groups |

`dist/nexus-install.lua` is the same installer, kept in the repository for
the `wget` above; rebuild it with any change to the installer
(`lua tools/mkinstaller.lua dist/nexus-install.lua`; a test checks it).

Optional groups are `installer/groups.lua` (the debug tools) and one per
driver in `drivers.idx`; leaving one out also drops its lines from
`/etc/modules.lua` and `drivers.idx`. After publishing a release, set its
tag in `dist/channel.lua` on `dev-oc`; the online installer reads it from
there (GitHub's `releases/latest` skips pre-releases).

`INSTALLER_REV` in `installer/src/prelude.lua` is the installer's revision.
Raise it when a release needs a newer installer; older installers update
themselves from such a release before installing. `manifest.lua`'s
`format` changes only when older installers would misread it.

## Requirements

- An internet card for the online install, or a release on a disk.
- A data card makes unpacking and booting faster; without one, zlib blocks
  are inflated in Lua (`/boot/nexusos` can be stored uncompressed then).
- About 600 KB free on the target (plus the downloads when online).

## Images with /usr

Images made by `lua tools/nximg.lua build` still hold `usr` and `etc`
sections (installs before 0.0.8, and the `ocelot/nexusos-*` test disks).
The boot loader sees the `usr` section and passes `image=`, and the kernel
mounts `/usr` read-only from the image as before.

Development disks (`build.lua`) boot `root/init.lua`, which loads a plain
`/boot/kernel.lua`; `build.lua` writes the `.meta` files of `/usr` with the
same modes and owners as the installer.
