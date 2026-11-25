#!/usr/bin/env node
// debugserver.js - receives the Nexus TCP debug console (netconsole).
// Copyright (c) 2026 akki697222
// SPDX-License-Identifier: MIT
//
//   node tools/debugserver/debugserver.js [--host H] [--port P] [--log FILE]
//
// Point the kernel at it in /boot/config.lua:
//   debug_console = { tcp = "127.0.0.1:7777" }
// The computer needs an internet card, and OpenComputers (Ocelot too) has to
// allow the address: put "allow ip:127.0.0.1" first in internet.filteringRules
// of OpenComputers.conf. Every line a computer sends is printed with the time
// and the client it came from, and appended to --log if given. No packages
// are needed.
"use strict";

const net = require("net");
const fs = require("fs");

function usage(error) {
    if (error) console.error("debugserver: " + error);
    console.error("usage: debugserver.js [--host H] [--port P] [--log FILE]  (default 127.0.0.1:7777)");
    process.exit(2);
}

const options = { host: "127.0.0.1", port: 7777, log: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const value = () => (i + 1 < argv.length ? argv[++i] : usage(argv[i] + " needs a value"));
    switch (argv[i]) {
        case "--host": options.host = value(); break;
        case "--port": options.port = Number(value()); break;
        case "--log": options.log = value(); break;
        case "-h": case "--help": usage(); break;
        default: usage("unknown argument " + argv[i]);
    }
}
if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535) usage("bad port");

const logFile = options.log ? fs.createWriteStream(options.log, { flags: "a" }) : null;
const colors = process.stdout.isTTY;
const LEVEL_COLORS = { emerg: 31, alert: 31, crit: 31, err: 31, warning: 33, notice: 36, debug: 90 };

function clock() {
    return new Date().toTimeString().slice(0, 8);
}

function show(client, line) {
    let text = line;
    if (colors) {
        // "[  12.34] level   tag: message": color by level
        const level = (line.match(/^\[[^\]]*\]\s+(\S+)/) || [])[1];
        if (LEVEL_COLORS[level]) text = "\x1b[" + LEVEL_COLORS[level] + "m" + line + "\x1b[0m";
    }
    console.log(clock() + " " + client + " " + text);
    if (logFile) logFile.write(clock() + " " + client + " " + line + "\n");
}

let nextId = 1;
const server = net.createServer((socket) => {
    const client = "#" + nextId++;
    const from = socket.remoteAddress + ":" + socket.remotePort;
    show(client, "-- connected from " + from);
    let pending = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
        pending += chunk;
        let nl;
        while ((nl = pending.indexOf("\n")) >= 0) {
            show(client, pending.slice(0, nl));
            pending = pending.slice(nl + 1);
        }
    });
    socket.on("close", () => {
        if (pending) show(client, pending);
        show(client, "-- disconnected");
    });
    socket.on("error", (e) => show(client, "-- error: " + e.message));
});

server.on("error", (e) => {
    console.error("debugserver: " + e.message);
    process.exit(1);
});
server.listen(options.port, options.host, () => {
    console.error("debugserver: listening on " + options.host + ":" + options.port
        + (options.log ? ", logging to " + options.log : ""));
});
