#!/bin/sh
# Launcher entry (stock and Onion layout): see Apps/slot link probe.pak.
cd "$(dirname "$0")" || exit 1
root="$(cd ../.. && pwd)"
sh "$root/System/linkprobe.sh" "$root" > "$root/slot-linkprobe.txt" 2>&1
sync
