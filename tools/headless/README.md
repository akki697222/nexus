# nexus-headless

Runs an OpenComputers machine without a window on ocelot-brain, the emulator
inside Ocelot Desktop, and drives it from a script: type keys, wait for text
on the screen, print the screen. It is meant for checking boot, login and
shell behaviour from a terminal or an agent, with the same emulation as
Ocelot Desktop.

## Requirements

- A JDK 11 or newer (`javac` and `java`).
- The Ocelot Desktop jar. `nexus-headless.sh` uses `$OCELOT_JAR`, or the newest
  `ocelot-desktop-*.jar` in `../ocelot-bin` next to the nexus repository.
  The jar is not part of this repository.

`nexus-headless.sh` compiles `NexusHeadless.java` into
`$NEXUS_HEADLESS_CLASSES` (default `/tmp/nexus-headless-classes`) when the
source is newer, then runs it.

## The machine

A tier 3 case with a tier 3 CPU (Lua 5.3), two tier 3.5 memory modules, a GPU
and screen (tier 3), a keyboard, a tier 1 data card and the Lua BIOS, plus one
managed hard drive per `--disk`. The first disk is written into the EEPROM as
the boot disk.

```sh
tools/headless/nexus-headless.sh [options] [script|-]
```

| option | |
| --- | --- |
| `--disk DIR` | a hard drive backed by DIR; changes are written to DIR (repeatable, the first boots) |
| `--disk-copy DIR` | the same on a temporary copy of DIR, which stays untouched |
| `--eeprom FILE` | EEPROM code instead of the Lua BIOS |
| `--arch 5.2\|5.3` | CPU architecture (default 5.3) |
| `--data-card 0-3` | data card tier, 0 for none (default 1) |
| `--internet` | add an internet card |
| `--screen-tier 1-3` | GPU and screen tier (default 3) |
| `--tick-ms N` | real milliseconds per tick (default 50, as in the game); 10 runs about 4x faster |
| `--wait-timeout S` | default timeout of `wait` (default 30 s) |

Times in scripts are machine time: 20 ticks a second, whatever `--tick-ms` is.

## Scripts

One command per line; `#` starts a comment. Strings are in double quotes and
take `\n` (Enter), `\t` (Tab), `\b` (Backspace), `\\` and `\"`.

| command | |
| --- | --- |
| `wait "text" [S]` | until the screen shows text (fails after S seconds) |
| `gone "text" [S]` | until the screen no longer shows text |
| `type "text"` | type the characters, one key press each |
| `key NAME [N]` | press a key N times: `enter tab backspace delete escape up down left right home end pageup pagedown space`, or `ctrl+c` and the like |
| `sleep S` | let S seconds pass |
| `screen [title]` | print the screen |
| `expect "text"` / `refuse "text"` | fail unless / if the screen shows text now |
| `running` | fail unless the machine is running |
| `stopped [S]` | until the machine stops (shutdown or crash) |
| `reboot` | stop the machine and start it again |

`wait` looks at the whole screen, including what was there before the last
input. Wait for text that only the expected output contains (a prompt with
the user name, `[sudo] password for alice: `), not a word that is already on
the screen. Prefer `wait` to `sleep`: echo and output can lag behind typing.

The exit status is 0 when the script ran through, 1 when a check failed (the
message names the line, and the screen is printed), 2 for bad usage. A crash
of the machine fails the script with the error and the screen.

## Examples

```sh
# a fresh release image: first boot setup, login, sudo
mkdir -p /tmp/disk/boot
cp dist/nexusos dist/config.lua /tmp/disk/boot/ && cp dist/init.lua /tmp/disk/
tools/headless/nexus-headless.sh --tick-ms 10 --disk /tmp/disk tools/headless/examples/firstboot.txt

# the development zlib disk, left as it is
tools/headless/nexus-headless.sh --tick-ms 10 --disk-copy ../ocelot/nexusos-zlib tools/headless/examples/login-debug.txt

# from standard input
printf 'wait "Login: " 60\nscreen\n' | tools/headless/nexus-headless.sh --disk-copy ../ocelot/boot -
```

The disk directories are read and written directly, so `/var/log/messages`
and other files can be inspected after a run (with `--disk`), or the copy
printed on standard error (with `--disk-copy`).
