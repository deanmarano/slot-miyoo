#!/bin/sh
# Contract tests for System/slotlink.sh, the Miyoo one.
#
# The contract is slot's, in crates/slot/src/link_radio.rs: five subcommands,
# exit 0 for success, exit 3 for "no host out there" and anything else for a
# fault. Exit 3 is the one worth testing hardest -- slot shows a patient
# waiting screen for it and a red error for every other code, so getting it
# wrong turns "nobody is hosting yet" into "the link is broken".
#
# Everything the script touches is faked: no radio is involved and this runs on
# the build host. Shaped after upstream's card/test-slotlink.sh.
#
# usage: sh card/test-slotlink-miyoo.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/System/slotlink.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
FAILS=0

fail() {
	echo "FAIL: $*"
	FAILS=$((FAILS + 1))
}

make_fake() {
	name="$1"
	out="$2"
	shift 2
	{
		echo '#!/bin/sh'
		echo "printf '%s\\n' \"\$*\" >> \"$out\""
		for line in "$@"; do echo "$line"; done
		echo 'exit 0'
	} > "$TMP/bin/$name"
	chmod 755 "$TMP/bin/$name"
}

# $1 = yes to give wlan0 a phy80211, i.e. a cfg80211 driver
reset() {
	rm -rf "$TMP/net" "$TMP/run" "$TMP"/*.log "$TMP/bin"
	mkdir -p "$TMP/net/wlan0" "$TMP/run" "$TMP/bin"
	[ "$1" = yes ] && : > "$TMP/net/wlan0/phy80211"
	make_fake wpa_cli "$TMP/cli.log" 'echo "wpa_state=${FAKE_STATE:-COMPLETED}"'
	make_fake wpa_supplicant "$TMP/sup.log"
	make_fake ip "$TMP/ip.log"
	# Nothing was holding the radio, so `down` has nothing to restore.
	make_fake pgrep "$TMP/pgrep.log" 'exit 1'
	make_fake killall "$TMP/killall.log"
	make_fake ifconfig "$TMP/ifconfig.log"
}

run() {
	PATH="$TMP/bin:$PATH" \
		SLOT_NET_SYS="$TMP/net" SLOT_LINK_RUN="$TMP/run" SLOT_ROOT="$TMP" \
		SLOT_WPA_SUPPLICANT="$TMP/bin/wpa_supplicant" \
		SLOT_WPA_CLI="$TMP/bin/wpa_cli" SLOT_IP="$TMP/bin/ip" \
		SLOT_LINK_WAIT_S=1 SLOT_LINK_JOIN_S=1 \
		SLOT_LINK_TRACE="$TMP/trace.txt" \
		sh "$SCRIPT" "$@"
}

conf="$TMP/run/link.conf"

# -- host -------------------------------------------------------------------
reset yes
run link host && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "host exited $rc"
grep -q 'mode=2' "$conf" || fail "host config is not an AP"
grep -q 'ap_scan=2' "$conf" || fail "host scans instead of starting a network"
# 2437, not upstream's 5745: this radio has no 5 GHz at all.
grep -q 'frequency=2437' "$conf" || fail "host is not on a 2.4 GHz channel"
# These two must match the Anbernic's defaults or the handhelds never meet.
grep -q 'ssid="slotlink"' "$conf" || fail "host SSID is not upstream's"
grep -q 'psk="slotlink0"' "$conf" || fail "host PSK is not upstream's"
grep -q '10.42.0.1' "$TMP/ip.log" || fail "host did not take 10.42.0.1"

# -- the driver flag is detected, not assumed --------------------------------
grep -q '\-Dnl80211' "$TMP/sup.log" || fail "a cfg80211 iface was not driven with nl80211"

reset no
run link host >/dev/null 2>&1 || true
grep -q '\-Dwext' "$TMP/sup.log" || fail "a wext-only iface was not driven with wext"

# -- join -------------------------------------------------------------------
reset yes
run link join && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "join exited $rc"
grep -q 'mode=2' "$conf" && fail "join brought up an AP"
# The host picks the channel and may be an Anbernic on one we did not choose.
grep -q 'frequency=' "$conf" && fail "join pinned a frequency"
grep -q '10.42.0.2' "$TMP/ip.log" || fail "join did not take 10.42.0.2"

# -- join with nobody hosting is exit 3, not a failure -----------------------
reset yes
FAKE_STATE=SCANNING run link join && rc=0 || rc=$?
[ "$rc" = 3 ] || fail "join with no host exited $rc, slot needs 3"

# -- a real fault is not exit 3 ----------------------------------------------
reset yes
rm -rf "$TMP/net/wlan0"
run link join && rc=0 || rc=$?
[ "$rc" = 3 ] && fail "a missing interface was reported as 'no host'"
[ "$rc" = 0 ] && fail "a missing interface was reported as success"

# -- down and cool always succeed --------------------------------------------
reset yes
run link down && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "down exited $rc"
run link cool && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "cool exited $rc"

# -- warm needs the interface and nothing else -------------------------------
reset yes
run link warm && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "warm exited $rc"
# Warm runs whenever a link-capable cart is seated; taking the radio there
# would drop the user's network for a game they have not started.
[ -s "$TMP/sup.log" ] && fail "warm started a supplicant"

# -- anything else is a usage error ------------------------------------------
reset yes
run link sideways && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "an unknown verb exited $rc, expected 2"
run && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "no arguments exited $rc, expected 2"

if [ "$FAILS" = 0 ]; then
	echo "slotlink (miyoo): all checks passed"
else
	echo "slotlink (miyoo): $FAILS failed"
	exit 1
fi
