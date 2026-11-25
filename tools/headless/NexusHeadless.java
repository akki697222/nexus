// NexusHeadless - run an OpenComputers machine headless on ocelot-brain (the
// emulator inside Ocelot Desktop) and drive it from a script: type keys,
// wait for text on the screen, print the screen.
//
// Copyright (c) 2026 akki697222
// SPDX-License-Identifier: MIT
//
//   java -cp <ocelot-desktop.jar>:<classes> NexusHeadless [options] [script|-]
//
// See tools/headless/README.md for the options and the script language.

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

import scala.Option;
import totoro.ocelot.brain.Ocelot;
import totoro.ocelot.brain.entity.*;
import totoro.ocelot.brain.entity.machine.Machine;
import totoro.ocelot.brain.entity.machine.luac.NativeLua52Architecture;
import totoro.ocelot.brain.entity.machine.luac.NativeLua53Architecture;
import totoro.ocelot.brain.entity.traits.Entity;
import totoro.ocelot.brain.loot.Loot;
import totoro.ocelot.brain.user.User;
import totoro.ocelot.brain.util.ExtendedTier$;
import totoro.ocelot.brain.util.Tier$;
import totoro.ocelot.brain.workspace.Workspace;
import totoro.ocelot.brain.entity.machine.Arguments;
import totoro.ocelot.brain.entity.machine.Callback;
import totoro.ocelot.brain.entity.machine.Context;
import totoro.ocelot.brain.event.Event;
import totoro.ocelot.brain.event.EventBus$;
import totoro.ocelot.brain.network.Component;
import totoro.ocelot.brain.network.Network;
import totoro.ocelot.brain.network.Visibility$;

public class NexusHeadless {
    static final int TICK_MS_DEFAULT = 50;

    // ---------------------------------------------------------------- options

    static final List<Path> disks = new ArrayList<>();
    static Path eepromFile;
    static String arch = "5.3";
    static int dataCard = 1;
    static boolean internet = false;
    static int screenTier = 3;
    static int tickMs = TICK_MS_DEFAULT;
    static double defaultWait = 30;
    static String script = null;
    static String ocelotLog = null;   // --ocelot-log TARGET
    static String serialLog = null;   // --serial TARGET
    static int netconsolePort = -1;   // --netconsole PORT[:TARGET]
    static String netconsoleLog = "-";

    static void usage(String error) {
        if (error != null) System.err.println("nexus-headless: " + error);
        System.err.println(String.join("\n",
            "usage: nexus-headless [options] [script|-]",
            "  --disk DIR          managed hard drive backed by DIR (repeatable; the first boots)",
            "  --disk-copy DIR     the same on a temporary copy of DIR, which is left untouched",
            "  --eeprom FILE       EEPROM code (default: the Lua BIOS)",
            "  --arch 5.2|5.3      CPU architecture (default 5.3)",
            "  --data-card 0-3     data card tier, 0 for none (default 1)",
            "  --internet          add an internet card",
            "  --screen-tier 1-3   screen and GPU tier (default 3)",
            "  --tick-ms N         real milliseconds per 1/20 s tick (default 50; lower runs faster)",
            "  --ocelot-log T      add an Ocelot card; its log() lines go to T (a file, or - for stdout)",
            "  --serial T          add a serial port (component \"serial\"); what is written goes to T",
            "  --netconsole P[:T]  listen on 127.0.0.1:P and write what TCP clients send to T (default -);",
            "                      adds an internet card allowed to reach localhost",
            "  --wait-timeout S    default timeout of `wait` in seconds (default 30)",
            "script commands, one per line (# starts a comment):",
            "  wait \"text\" [S]     until the screen shows text (fails after S seconds)",
            "  gone \"text\" [S]     until the screen no longer shows text",
            "  type \"text\"         type characters; \\n is Enter, \\t Tab, \\b Backspace",
            "  key NAME [N]        press a key N times: enter tab backspace delete up down left",
            "                      right home end pageup pagedown escape, or ctrl+c and the like",
            "  sleep S             let S seconds of machine time pass",
            "  screen              print the screen",
            "  wait-log \"text\" [S] until the debug output (Ocelot card, serial, netconsole) shows text",
            "  expect \"text\"       fail unless the screen shows text now",
            "  refuse \"text\"       fail if the screen shows text now",
            "  running             fail unless the machine is running",
            "  stopped [S]         until the machine has stopped (shutdown or crash)",
            "  reboot              stop the machine and start it again",
            "exit status: 0 done, 1 a check failed, 2 bad usage"));
        System.exit(2);
    }

    static void parseArgs(String[] args) {
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            switch (a) {
                case "--disk": disks.add(Paths.get(next(args, ++i, a)).toAbsolutePath()); break;
                case "--disk-copy": disks.add(copyOf(Paths.get(next(args, ++i, a)).toAbsolutePath())); break;
                case "--eeprom": eepromFile = Paths.get(next(args, ++i, a)); break;
                case "--arch": arch = next(args, ++i, a); break;
                case "--data-card": dataCard = Integer.parseInt(next(args, ++i, a)); break;
                case "--internet": internet = true; break;
                case "--screen-tier": screenTier = Integer.parseInt(next(args, ++i, a)); break;
                case "--tick-ms": tickMs = Integer.parseInt(next(args, ++i, a)); break;
                case "--wait-timeout": defaultWait = Double.parseDouble(next(args, ++i, a)); break;
                case "--ocelot-log": ocelotLog = next(args, ++i, a); break;
                case "--serial": serialLog = next(args, ++i, a); break;
                case "--netconsole": {
                    String v = next(args, ++i, a);
                    int colon = v.indexOf(':');
                    netconsolePort = Integer.parseInt(colon < 0 ? v : v.substring(0, colon));
                    if (colon >= 0) netconsoleLog = v.substring(colon + 1);
                    internet = true;
                    break;
                }
                case "-h": case "--help": usage(null); break;
                default:
                    if (a.startsWith("--")) usage("unknown option " + a);
                    if (script != null) usage("more than one script");
                    script = a;
            }
        }
        if (disks.isEmpty()) usage("no --disk given");
        for (Path d : disks) if (!Files.isDirectory(d)) usage("not a directory: " + d);
        if (!arch.equals("5.2") && !arch.equals("5.3")) usage("--arch must be 5.2 or 5.3");
        if (dataCard < 0 || dataCard > 3) usage("--data-card must be 0-3");
        if (screenTier < 1 || screenTier > 3) usage("--screen-tier must be 1-3");
        if (tickMs < 0) usage("--tick-ms must not be negative");
    }

    // a temporary copy of a directory tree (for --disk-copy)
    static Path copyOf(Path source) {
        if (!Files.isDirectory(source)) usage("not a directory: " + source);
        try {
            Path target = Files.createTempDirectory("nexus-headless-disk");
            try (java.util.stream.Stream<Path> walk = Files.walk(source)) {
                for (Path p : (Iterable<Path>) walk::iterator) {
                    Path dest = target.resolve(source.relativize(p).toString());
                    if (Files.isDirectory(p)) Files.createDirectories(dest);
                    else Files.copy(p, dest, StandardCopyOption.REPLACE_EXISTING);
                }
            }
            System.err.println("nexus-headless: " + source + " copied to " + target);
            return target;
        } catch (IOException e) {
            usage("cannot copy " + source + ": " + e.getMessage());
            return null;
        }
    }

    static String next(String[] args, int i, String option) {
        if (i >= args.length) usage(option + " needs a value");
        return args[i];
    }

    // ---------------------------------------------------------------- debug output

    // Everything the debug outputs received, for wait-log.
    static final StringBuffer debugOutput = new StringBuffer();

    // A target: "-" writes prefixed lines to stdout, anything else appends
    // the raw text to that file.
    static final class Sink {
        final String prefix;
        final Writer file;
        final StringBuilder partial = new StringBuilder();

        Sink(String prefix, String target) {
            this.prefix = prefix;
            try {
                this.file = target.equals("-") ? null
                    : new OutputStreamWriter(new FileOutputStream(target, true), StandardCharsets.UTF_8);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }

        synchronized void write(String text) {
            debugOutput.append(text);
            try {
                if (file != null) {
                    file.write(text);
                    file.flush();
                    return;
                }
            } catch (IOException e) {
                System.err.println("nexus-headless: " + prefix + ": " + e.getMessage());
                return;
            }
            partial.append(text);
            int nl;
            while ((nl = partial.indexOf("\n")) >= 0) {
                System.out.println(prefix + "| " + partial.substring(0, nl));
                partial.delete(0, nl + 1);
            }
            System.out.flush();
        }
    }

    static Sink ocelotSink, serialSink, netSink;

    // A serial port: component "serial" with write(data). Built on Keyboard,
    // a component without callbacks of its own.
    public static class SerialPort extends Keyboard {
        private Component serialNode;

        @Override
        public Component node() {
            if (serialNode == null) {
                serialNode = Network.newNode(this, Visibility$.MODULE$.Neighbors(), Network.newNode$default$3())
                    .withComponent("serial", Visibility$.MODULE$.Neighbors())
                    .create();
            }
            return serialNode;
        }

        @Callback(direct = true, doc = "function(data:string):number -- Writes data to the serial port.")
        public Object[] write(Context context, Arguments args) {
            byte[] data = args.checkByteArray(0);
            if (serialSink != null) serialSink.write(new String(data, StandardCharsets.UTF_8));
            return new Object[] { data.length };
        }
    }

    // log() lines of the Ocelot card arrive as events on the brain's bus.
    static final class OcelotLogListener extends scala.runtime.AbstractPartialFunction<Event, scala.runtime.BoxedUnit> {
        @Override
        public boolean isDefinedAt(Event e) {
            return e.getClass().getName().endsWith("LogEvent$CardToUser");
        }

        @Override
        @SuppressWarnings("unchecked")
        public <A1 extends Event, B1> B1 applyOrElse(A1 e, scala.Function1<A1, B1> fallback) {
            if (!isDefinedAt(e)) return fallback.apply(e);
            try {
                String message = (String) e.getClass().getMethod("message").invoke(e);
                if (ocelotSink != null) ocelotSink.write(message + "\n");
            } catch (ReflectiveOperationException ex) {
                System.err.println("nexus-headless: ocelot log: " + ex);
            }
            return (B1) scala.runtime.BoxedUnit.UNIT;
        }
    }

    // The netconsole: a TCP server on localhost; each line a client sends
    // goes to the sink.
    static void startNetconsole() throws IOException {
        java.net.ServerSocket server = new java.net.ServerSocket(netconsolePort, 8, java.net.InetAddress.getLoopbackAddress());
        netSink = new Sink("tcp", netconsoleLog);
        Thread acceptor = new Thread(() -> {
            while (true) {
                try {
                    java.net.Socket client = server.accept();
                    Thread reader = new Thread(() -> {
                        try (InputStream in = client.getInputStream()) {
                            byte[] buf = new byte[4096];
                            int n;
                            while ((n = in.read(buf)) > 0) netSink.write(new String(buf, 0, n, StandardCharsets.UTF_8));
                        } catch (IOException ignored) {
                        }
                    });
                    reader.setDaemon(true);
                    reader.start();
                } catch (IOException e) {
                    return;
                }
            }
        });
        acceptor.setDaemon(true);
        acceptor.start();
    }

    // The brain's configuration with the internet card allowed to reach
    // 127.0.0.1 (OC denies private addresses by default).
    static Path internetConfig(Path dir) throws IOException {
        String conf;
        try (InputStream in = NexusHeadless.class.getClassLoader().getResourceAsStream("application.conf")) {
            if (in == null) throw new IOException("application.conf not found in the jar");
            conf = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
        // "allow default" itself denies private addresses: allow loopback first
        conf = conf.replace("\"removeme\",", "\"allow ip:127.0.0.1\",");
        Path file = dir.resolve("brain.conf");
        Files.write(file, conf.getBytes(StandardCharsets.UTF_8));
        return file;
    }

    // ---------------------------------------------------------------- machine

    static Workspace workspace;
    static Case computer;
    static Screen screen;
    static final User user = User.apply("agent");

    static totoro.ocelot.brain.util.Tier.TierVal tier(int t) {
        return t == 1 ? Tier$.MODULE$.One() : t == 2 ? Tier$.MODULE$.Two() : Tier$.MODULE$.Three();
    }

    static void build() throws IOException {
        Path work = Files.createTempDirectory("nexus-headless");
        Ocelot.librariesPath_$eq(Option.apply(work));
        if (internet) Ocelot.configPath_$eq(Option.apply(internetConfig(work)));
        Ocelot.initialize();
        if (netconsolePort >= 0) startNetconsole();
        workspace = new Workspace(work);
        computer = workspace.add(new Case(Tier$.MODULE$.Three()));

        List<Entity> parts = new ArrayList<>();
        CPU cpu = new CPU(Tier$.MODULE$.Three());
        cpu.setArchitecture(arch.equals("5.2") ? NativeLua52Architecture.class : NativeLua53Architecture.class);
        parts.add(cpu);
        parts.add(new Memory(ExtendedTier$.MODULE$.ThreeHalf()));
        parts.add(new Memory(ExtendedTier$.MODULE$.ThreeHalf()));
        parts.add(new GraphicsCard(tier(screenTier)));
        if (dataCard == 1) parts.add(new DataCard.Tier1());
        if (dataCard == 2) parts.add(new DataCard.Tier2());
        if (dataCard == 3) parts.add(new DataCard.Tier3());
        if (internet) parts.add(new InternetCard());
        if (ocelotLog != null) {
            ocelotSink = new Sink("ocelot", ocelotLog);
            EventBus$.MODULE$.subscribe(new OcelotLogListener());
            parts.add(new ocelot.desktop.entity.OcelotCard());
        }
        if (serialLog != null) {
            serialSink = new Sink("serial", serialLog);
            parts.add(new SerialPort());
        }
        List<HDDManaged> hdds = new ArrayList<>();
        for (Path d : disks) {
            HDDManaged hdd = new HDDManaged(Tier$.MODULE$.Three());
            hdd.customRealPath_$eq(Option.apply(d));
            hdds.add(hdd);
            parts.add(hdd);
        }
        EEPROM eeprom = Loot.LuaBiosEEPROM().create();
        if (eepromFile != null) {
            eeprom = new EEPROM();
            eeprom.codeBytes_$eq(Option.apply(Files.readAllBytes(eepromFile)));
        }
        parts.add(eeprom);
        for (int i = 0; i < parts.size(); i++) computer.inventory().apply(i).put(parts.get(i));

        screen = workspace.add(new Screen(tier(screenTier)));
        Keyboard keyboard = workspace.add(new Keyboard());
        computer.connect(screen);
        screen.connect(keyboard);

        // boot the first disk: the Lua BIOS reads the boot address from the
        // EEPROM data
        String boot = hdds.get(0).node().address();
        eeprom.volatileData_$eq(boot.getBytes(StandardCharsets.UTF_8));
    }

    static void start() {
        if (!computer.machine().start()) fail("the machine did not start");
    }

    static void tick() {
        workspace.update();
        if (tickMs > 0) {
            try { Thread.sleep(tickMs); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
    }

    // machine time, in seconds (20 ticks a second, like Minecraft)
    static double now() {
        return workspace.getIngameTime() / 20.0;
    }

    // the screen as lines of text; trailing spaces are kept for matching
    // ("$ " at a prompt) and dropped for printing
    static String screenText(boolean trim) {
        int w = screen.getWidth(), h = screen.getHeight();
        StringBuilder sb = new StringBuilder();
        for (int y = 0; y < h; y++) {
            StringBuilder line = new StringBuilder();
            for (int x = 0; x < w; x++) {
                int cp = screen.getCodePoint(x, y);
                // the second cell of a double-width character holds nothing
                if (cp != 0) line.appendCodePoint(cp);
            }
            String text = line.toString();
            sb.append(trim ? text.replaceAll("\\s+$", "") : text).append('\n');
        }
        return trim ? sb.toString().replaceAll("\n+$", "\n") : sb.toString();
    }

    static boolean shows(String text) {
        return screenText(false).contains(text);
    }

    static void printScreen(String title) {
        String text = screenText(true);
        int w = screen.getWidth();
        String bar = "-".repeat(Math.max(4, Math.min(w, 80)));
        System.out.println("+" + bar + " " + title + " (t=" + String.format("%.1f", now()) + "s)");
        for (String line : text.split("\n")) System.out.println("|" + line);
        System.out.println("+" + bar);
        System.out.flush();
    }

    static void checkCrash() {
        Machine m = computer.machine();
        if (!m.isRunning() && m.lastError() != null) {
            printScreen("crashed");
            fail("machine crashed: " + m.lastError());
        }
    }

    // ---------------------------------------------------------------- input

    static final Map<String, int[]> KEYS = new HashMap<>();
    static {
        // name -> { char, LWJGL key code }
        KEYS.put("enter", new int[] { 13, 28 });
        KEYS.put("tab", new int[] { 9, 15 });
        KEYS.put("backspace", new int[] { 8, 14 });
        KEYS.put("delete", new int[] { 127, 211 });
        KEYS.put("escape", new int[] { 27, 1 });
        KEYS.put("up", new int[] { 0, 200 });
        KEYS.put("down", new int[] { 0, 208 });
        KEYS.put("left", new int[] { 0, 203 });
        KEYS.put("right", new int[] { 0, 205 });
        KEYS.put("home", new int[] { 0, 199 });
        KEYS.put("end", new int[] { 0, 207 });
        KEYS.put("pageup", new int[] { 0, 201 });
        KEYS.put("pagedown", new int[] { 0, 209 });
        KEYS.put("space", new int[] { 32, 57 });
    }
    static final String ROW1 = "1234567890-=", ROW1S = "!@#$%^&*()_+";
    static final String QROW = "qwertyuiop[]", AROW = "asdfghjkl;'`", ZROW = "zxcvbnm,./";
    static final String QROWS = "QWERTYUIOP{}", AROWS = "ASDFGHJKL:\"~", ZROWS = "ZXCVBNM<>?";

    // LWJGL key code of a character on a US keyboard (0 when there is none)
    static int codeOf(char c) {
        int i;
        if ((i = ROW1.indexOf(c)) >= 0 || (i = ROW1S.indexOf(c)) >= 0) return 2 + i;
        if ((i = QROW.indexOf(c)) >= 0 || (i = QROWS.indexOf(c)) >= 0) return 16 + i;
        if ((i = AROW.indexOf(c)) >= 0 || (i = AROWS.indexOf(c)) >= 0) return 30 + i;
        if ((i = ZROW.indexOf(c)) >= 0 || (i = ZROWS.indexOf(c)) >= 0) return 44 + i;
        if (c == '\\' || c == '|') return 43;
        if (c == ' ') return 57;
        return 0;
    }

    static void press(char ch, int code) {
        screen.keyDown(ch, code, user);
        tick();
        screen.keyUp(ch, code, user);
        tick();
    }

    static void typeText(String text) {
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\n') press((char) 13, 28);
            else if (c == '\t') press((char) 9, 15);
            else if (c == '\b') press((char) 8, 14);
            else press(c, codeOf(c));
            checkCrash();
        }
    }

    static void pressKey(String name) {
        name = name.toLowerCase(Locale.ROOT);
        if (name.startsWith("ctrl+") && name.length() == 6) {
            char c = name.charAt(5);
            screen.keyDown((char) 0, 29, user); // left control
            tick();
            press((char) (Character.toLowerCase(c) - 'a' + 1), codeOf(c));
            screen.keyUp((char) 0, 29, user);
            tick();
            return;
        }
        int[] k = KEYS.get(name);
        if (k == null) fail("unknown key: " + name);
        press((char) k[0], k[1]);
    }

    // ---------------------------------------------------------------- script

    static int lineNo = 0;
    static String lineText = "";

    static void fail(String message) {
        System.out.flush();
        String where = lineNo > 0 ? "line " + lineNo + " (" + lineText.trim() + "): " : "";
        System.err.println("nexus-headless: " + where + message);
        if (computer != null && screen != null && !message.startsWith("machine crashed")) printScreen("at failure");
        System.exit(1);
    }

    // splits a line into words; "quoted strings" keep spaces and take \n \t \b \\ \"
    static List<String> words(String line) {
        List<String> out = new ArrayList<>();
        int i = 0, n = line.length();
        while (i < n) {
            char c = line.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '#') break;
            StringBuilder w = new StringBuilder();
            if (c == '"') {
                i++;
                boolean closed = false;
                while (i < n) {
                    char d = line.charAt(i++);
                    if (d == '"') { closed = true; break; }
                    if (d == '\\' && i < n) {
                        char e = line.charAt(i++);
                        switch (e) {
                            case 'n': w.append('\n'); break;
                            case 't': w.append('\t'); break;
                            case 'b': w.append('\b'); break;
                            default: w.append(e);
                        }
                    } else w.append(d);
                }
                if (!closed) fail("unterminated string");
            } else {
                while (i < n && !Character.isWhitespace(line.charAt(i))) w.append(line.charAt(i++));
            }
            out.add(w.toString());
        }
        return out;
    }

    static double seconds(List<String> w, int i, double fallback) {
        return w.size() > i ? Double.parseDouble(w.get(i)) : fallback;
    }

    static void waitFor(String text, double timeout, boolean present) {
        double deadline = now() + timeout;
        while (shows(text) != present) {
            checkCrash();
            if (now() >= deadline) {
                fail((present ? "timed out waiting for " : "timed out waiting for the screen to drop ")
                    + "\"" + text.replace("\n", "\\n") + "\" (" + timeout + "s)");
            }
            tick();
        }
    }

    static void run(BufferedReader in) throws IOException {
        String line;
        while ((line = in.readLine()) != null) {
            lineNo++;
            lineText = line;
            List<String> w = words(line);
            if (w.isEmpty()) continue;
            String cmd = w.get(0);
            switch (cmd) {
                case "wait": need(w, 2); waitFor(w.get(1), seconds(w, 2, defaultWait), true); break;
                case "gone": need(w, 2); waitFor(w.get(1), seconds(w, 2, defaultWait), false); break;
                case "type": need(w, 2); typeText(w.get(1)); break;
                case "key": {
                    need(w, 2);
                    int times = w.size() > 2 ? Integer.parseInt(w.get(2)) : 1;
                    for (int k = 0; k < times; k++) pressKey(w.get(1));
                    break;
                }
                case "sleep": {
                    need(w, 2);
                    double until = now() + Double.parseDouble(w.get(1));
                    while (now() < until) { checkCrash(); tick(); }
                    break;
                }
                case "screen": printScreen(w.size() > 1 ? w.get(1) : "screen"); break;
                case "wait-log": {
                    need(w, 2);
                    double deadline = now() + seconds(w, 2, defaultWait);
                    while (debugOutput.indexOf(w.get(1)) < 0) {
                        checkCrash();
                        if (now() >= deadline) fail("timed out waiting for \"" + w.get(1) + "\" in the debug output");
                        tick();
                    }
                    break;
                }
                case "expect": need(w, 2); if (!shows(w.get(1))) fail("screen does not show \"" + w.get(1) + "\""); break;
                case "refuse": need(w, 2); if (shows(w.get(1))) fail("screen shows \"" + w.get(1) + "\""); break;
                case "running": checkCrash(); if (!computer.machine().isRunning()) fail("the machine is not running"); break;
                case "stopped": {
                    double deadline = now() + seconds(w, 1, defaultWait);
                    while (computer.machine().isRunning()) {
                        if (now() >= deadline) fail("the machine is still running");
                        tick();
                    }
                    String err = computer.machine().lastError();
                    System.out.println("machine stopped" + (err != null ? ": " + err : ""));
                    break;
                }
                case "reboot": {
                    computer.machine().stop();
                    for (int k = 0; k < 10; k++) tick();
                    start();
                    break;
                }
                default: fail("unknown command: " + cmd);
            }
        }
        lineNo = 0;
    }

    static void need(List<String> w, int n) {
        if (w.size() < n) fail(w.get(0) + ": missing argument");
    }

    public static void main(String[] args) throws Exception {
        parseArgs(args);
        build();
        start();
        BufferedReader in = script == null || script.equals("-")
            ? new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))
            : Files.newBufferedReader(Paths.get(script), StandardCharsets.UTF_8);
        run(in);
        computer.machine().stop();
        for (int k = 0; k < 5; k++) workspace.update();
        Ocelot.shutdown();
        System.exit(0);
    }
}
