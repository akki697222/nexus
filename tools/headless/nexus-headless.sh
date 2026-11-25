#!/bin/sh
# nexus-headless.sh - compile (when needed) and run NexusHeadless on the
# ocelot-brain inside the Ocelot Desktop jar. Arguments go to NexusHeadless;
# see README.md.
#
# The jar is $OCELOT_JAR, or the newest ocelot-desktop-*.jar in
# ../ocelot-bin next to the nexus repository.
set -e
here=$(cd "$(dirname "$0")" && pwd)
jar=${OCELOT_JAR:-}
if [ -z "$jar" ]; then
    for candidate in "$here"/../../../ocelot-bin/ocelot-desktop-*.jar; do
        [ -f "$candidate" ] && jar=$candidate
    done
fi
if [ -z "$jar" ] || [ ! -f "$jar" ]; then
    echo "nexus-headless: Ocelot Desktop jar not found; set OCELOT_JAR" >&2
    exit 2
fi
classes=${NEXUS_HEADLESS_CLASSES:-${TMPDIR:-/tmp}/nexus-headless-classes}
src=$here/NexusHeadless.java
if [ ! -f "$classes/NexusHeadless.class" ] || [ "$src" -nt "$classes/NexusHeadless.class" ]; then
    mkdir -p "$classes"
    javac --release 11 -proc:none -nowarn -cp "$jar" -d "$classes" "$src"
fi
exec java -cp "$jar:$classes" NexusHeadless "$@"
