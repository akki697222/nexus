# debugserver

Receives the Nexus TCP debug console (netconsole): every kernel log line,
from the first boot line to a panic, sent through an internet card.

```sh
node tools/debugserver/debugserver.js [--host H] [--port P] [--log FILE]
```

It listens on 127.0.0.1:7777 by default, prints each line with the time and
the client it came from (colored by level on a terminal), and appends to
`--log` if given. Node.js only, no packages.

On the computer:

- an internet card;
- `/boot/config.lua`: `debug_console = { tcp = "127.0.0.1:7777" }` (keep
  `ocelot` and `serial` as they are if you want those too);
- OpenComputers denies private addresses by default. In Ocelot Desktop
  (`ocelot-bin/OpenComputers.conf`) or a Minecraft instance
  (`config/opencomputers/settings.conf`), put `"allow ip:127.0.0.1"` first in
  `internet.filteringRules`. Another host on the LAN needs its own address
  there, and `--host 0.0.0.0` here.

The kernel connects at boot and again after a loss (every 5 s), sends what
the klog ring still holds when it connects, and tries to get a panic out
before the machine halts. `tools/headless` has the same server built in
(`--netconsole`).
