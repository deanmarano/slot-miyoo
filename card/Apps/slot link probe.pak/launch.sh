#!/bin/sh
# Launcher entry: can this handheld host a two-player link, or only join one?
# The work is in System/linkprobe.sh; the answer lands in slot-linkprobe.txt
# at the card root.
cd "$(dirname "$0")" || exit 1
root="$(cd ../.. && pwd)"
sh "$root/System/linkprobe.sh" "$root" > "$root/slot-linkprobe.txt" 2>&1
sync
