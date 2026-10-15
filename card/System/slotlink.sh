#!/bin/sh
# The private WiFi that slot's two-player link runs over, for this radio.
#
# slot calls this script and nothing else to get a link up:
#   slotlink.sh link warm   make the radio ready, cheaply
#   slotlink.sh link host   become the AP;        address 10.42.0.1
#   slotlink.sh link join   find the AP;          address 10.42.0.2, exit 3 if
#                           there is no host out there to find
#   slotlink.sh link down   put everything back
#   slotlink.sh link cool   nothing to do here
# (crates/slot/src/link_radio.rs). slot then opens TCP 10.42.0.1:7211 across it
# and carries mGBA's serial data. Those addresses and that port are upstream's
# and are compiled in -- HOST_ADDR in link_start.rs -- so this script's whole
# job is to make 10.42.0.1 and 10.42.0.2 exist on the right two handhelds.
#
# This replaces upstream's card/System/slotlink.sh, which cannot work here. It
# is written for the Anbernic H700 radio and makes three assumptions this one
# breaks:
#
#   upstream                        this device (rtl8188fu, measured)
#   ---------------------------     -----------------------------------------
#   AP on a second iface, wlan1     one interface, wlan0. Both roles share it
#   wpa_supplicant -Dnl80211        vendor driver may be wext-only -> detected
#   meets on 5745 MHz (5 GHz)       2.4 GHz only -> channel 6, 2437 MHz
#
# The SSID and passphrase deliberately keep upstream's defaults, because the
# other end of the link is an unmodified Anbernic running the upstream script
# and the two have to agree. Do not "improve" them on one side only.
#
# THE FREQUENCY DOES NOT AGREE, and cannot: upstream meets on 5745 MHz and this
# radio has no 5 GHz. Whichever handheld hosts picks the channel, so:
#   - this device hosts -> works as shipped, the Anbernic scans and finds it
#     (upstream's join retries on every channel after its first pinned attempt)
#   - the Anbernic hosts -> it must be told a 2.4 GHz channel,
#     AGS_LINK_FREQ=2437, or this device cannot see the network at all
# docs/link.md spells that out.
#
# Busybox sh: no bashisms, no local, every tool optional.

set -u

NET="${SLOT_NET_SYS:-/sys/class/net}"
RUN="${SLOT_LINK_RUN:-/tmp/slotlink}"
ROOT="${SLOT_ROOT:-/mnt/SDCARD}"

# Upstream's defaults, and they must stay upstream's -- see above. AGS_* names
# are honoured first so one exported variable configures both ends the same way.
LINK_SSID="${AGS_LINK_SSID:-${SLOT_LINK_SSID:-slotlink}}"
LINK_PSK="${AGS_LINK_PSK:-${SLOT_LINK_PSK:-slotlink0}}"
# 2437 = channel 6. Not upstream's 5745: this radio is 2.4 GHz only.
LINK_FREQ="${AGS_LINK_FREQ:-${SLOT_LINK_FREQ:-2437}}"
LINK_HOST_IP="${SLOT_LINK_HOST_IP:-10.42.0.1/24}"
LINK_PEER_IP="${SLOT_LINK_PEER_IP:-10.42.0.2/24}"
# How long to wait for the AP to come up, and for a join to find a host. The
# join bound is what slot turns into "no host"; 20 s is two full scans on this
# chip, which is slow to answer from cold.
LINK_WAIT_S="${SLOT_LINK_WAIT_S:-12}"
LINK_JOIN_S="${SLOT_LINK_JOIN_S:-20}"
# Empty means detect. Set to nl80211 or wext to pin it, once linkprobe.sh has
# said which this firmware's wpa_supplicant actually drives this chip with.
LINK_DRIVER="${SLOT_LINK_DRIVER:-}"
TRACE="${SLOT_LINK_TRACE:-$ROOT/slot-link.txt}"

IFACE=wlan0
CTRL="$RUN/ctrl"
CONF="$RUN/link.conf"
MARK="$RUN/session"
# What was running before we took the radio, so `down` can give it back.
PRIOR="$RUN/prior-supplicant"

WPA_SUPPLICANT="${SLOT_WPA_SUPPLICANT:-wpa_supplicant}"
WPA_CLI="${SLOT_WPA_CLI:-wpa_cli}"
IP="${SLOT_IP:-ip}"

# Every run appends, because the useful question is almost always "what did it
# do the last three times", and a link that fails intermittently is the kind
# this radio produces. Truncated when it gets silly.
trace() {
	[ -n "$TRACE" ] || return 0
	if [ -f "$TRACE" ] && [ "$(wc -c < "$TRACE" 2>/dev/null || echo 0)" -gt 65536 ]; then
		tail -c 16384 "$TRACE" > "$TRACE.tmp" 2>/dev/null && mv "$TRACE.tmp" "$TRACE"
	fi
	echo "slotlink $(cut -d' ' -f1 /proc/uptime 2>/dev/null): $*" >> "$TRACE" 2>/dev/null
	return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# ip, or ifconfig where the firmware has no ip. Both are busybox here but a
# card is not guaranteed to carry either applet.
if_up() {
	$IP link set "$1" up 2>/dev/null || ifconfig "$1" up 2>/dev/null || true
}

addr_set() {
	$IP addr add "$2" dev "$1" 2>/dev/null \
		|| ifconfig "$1" "${2%/*}" netmask 255.255.255.0 2>/dev/null || true
}

addr_flush() {
	$IP addr flush dev "$1" 2>/dev/null || ifconfig "$1" 0.0.0.0 2>/dev/null || true
}

# The driver flag is the single likeliest reason this fails on a firmware other
# than the one it was written against, so it is detected rather than assumed:
# phy80211 in sysfs means cfg80211 underneath, and nl80211 will drive it. A
# Realtek vendor build without it answers wireless extensions only.
driver_flag() {
	if [ -n "$LINK_DRIVER" ]; then
		echo "$LINK_DRIVER"
	elif [ -e "$NET/$IFACE/phy80211" ]; then
		echo nl80211
	else
		echo wext
	fi
}

wait_iface() {
	w=0
	while [ ! -d "$NET/$1" ] && [ "$w" -lt "$2" ]; do
		sleep 0.25 2>/dev/null || sleep 1
		w=$((w + 1))
	done
	[ -d "$NET/$1" ]
}

# wlan0 does not exist until the module is insmodded, and Allium's wifi-on.sh
# is the thing that knows how this chip wants to be started -- which module,
# which firmware blob, in which order. Reimplementing that here would be a
# second place to keep it right, so it is called.
radio_up() {
	if [ -d "$NET/$IFACE" ]; then
		return 0
	fi
	if [ -x "$ROOT/.allium/scripts/wifi-on.sh" ]; then
		trace "insmod via wifi-on.sh"
		sh "$ROOT/.allium/scripts/wifi-on.sh" >/dev/null 2>&1
	fi
	wait_iface "$IFACE" 40
}

# Whatever supplicant owns wlan0 has to let go: there is one interface and the
# link needs it. Noted first so `down` can restart it.
seize() {
	mkdir -p "$RUN" 2>/dev/null
	if pgrep wpa_supplicant >/dev/null 2>&1; then
		echo yes > "$PRIOR"
		trace "taking wlan0 from the running supplicant"
	else
		echo no > "$PRIOR"
	fi
	# Ours first, by its own control socket, then anything else.
	$WPA_CLI -p "$CTRL" -i "$IFACE" terminate >/dev/null 2>&1
	killall wpa_supplicant 2>/dev/null
	killall udhcpc 2>/dev/null
	s=0
	while pgrep wpa_supplicant >/dev/null 2>&1 && [ "$s" -lt 8 ]; do
		sleep 0.25 2>/dev/null || sleep 1
		s=$((s + 1))
	done
	addr_flush "$IFACE"
	rm -rf "$CTRL"
	mkdir -p "$CTRL" 2>/dev/null
	return 0
}

# Poll wpa_state to COMPLETED, logging each change. $1 bound in seconds, $2
# rescan every N polls (0 for never -- an AP has nothing to scan for).
wait_state() {
	p=0
	was=
	state=
	end=$(( $1 * 4 ))
	while [ "$p" -lt "$end" ]; do
		state=$($WPA_CLI -p "$CTRL" -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p')
		if [ "$state" != "$was" ]; then
			trace "  ${state:-no answer}"
			was=$state
		fi
		[ "$state" = COMPLETED ] && return 0
		if [ "$2" -gt 0 ] && [ "$p" -gt 0 ] && [ $((p % $2)) -eq 0 ]; then
			case "$state" in
			DISCONNECTED | INACTIVE | SCANNING)
				$WPA_CLI -p "$CTRL" -i "$IFACE" scan >/dev/null 2>&1
				;;
			esac
		fi
		sleep 0.25 2>/dev/null || sleep 1
		p=$((p + 1))
	done
	return 1
}

start_supplicant() {
	drv=$(driver_flag)
	trace "wpa_supplicant -D$drv on $IFACE"
	if $WPA_SUPPLICANT -B -i "$IFACE" -c "$CONF" -D"$drv" >/dev/null 2>&1; then
		return 0
	fi
	# A wrong -D is the one failure worth retrying automatically, because it
	# costs a second and the alternative is a user reading a trace file to
	# learn their firmware wants the other flag.
	case "$drv" in
	nl80211) other=wext ;;
	*) other=nl80211 ;;
	esac
	trace "-D$drv would not start, falling back to -D$other"
	$WPA_SUPPLICANT -B -i "$IFACE" -c "$CONF" -D"$other" >/dev/null 2>&1
}

link_host() {
	trace "host: asked"
	have "$WPA_SUPPLICANT" || { trace "host: no wpa_supplicant"; return 1; }
	radio_up || { trace "host: no $IFACE"; return 1; }
	seize
	{
		echo "ctrl_interface=$CTRL"
		# ap_scan=2 is what tells wpa_supplicant to bring the network up
		# itself rather than look for one.
		echo 'ap_scan=2'
		echo 'network={'
		echo "	ssid=\"$LINK_SSID\""
		echo '	mode=2'
		echo "	frequency=$LINK_FREQ"
		echo '	key_mgmt=WPA-PSK'
		echo '	proto=RSN'
		echo '	pairwise=CCMP'
		echo "	psk=\"$LINK_PSK\""
		echo '}'
	} > "$CONF"
	chmod 600 "$CONF" 2>/dev/null
	if_up "$IFACE"
	start_supplicant || { trace "host: supplicant would not start"; return 1; }
	wait_state "$LINK_WAIT_S" 0 || { trace "host: AP never came up"; return 1; }
	addr_set "$IFACE" "$LINK_HOST_IP"
	echo "$$" > "$MARK"
	trace "host: up on ${LINK_FREQ}, ${LINK_HOST_IP%/*}"
	return 0
}

link_join() {
	trace "join: asked"
	have "$WPA_SUPPLICANT" || { trace "join: no wpa_supplicant"; return 1; }
	radio_up || { trace "join: no $IFACE"; return 1; }
	seize
	{
		echo "ctrl_interface=$CTRL"
		echo 'network={'
		echo "	ssid=\"$LINK_SSID\""
		echo '	key_mgmt=WPA-PSK'
		echo "	psk=\"$LINK_PSK\""
		# Not pinned to one frequency: the host decides the channel, and if
		# the other end is an Anbernic it may be somewhere this script did not
		# choose. Scanning everything is slower and always correct.
		echo '}'
	} > "$CONF"
	chmod 600 "$CONF" 2>/dev/null
	if_up "$IFACE"
	start_supplicant || { trace "join: supplicant would not start"; return 1; }
	# Rescan every 2 s while it hunts; this chip sits in SCANNING otherwise.
	if ! wait_state "$LINK_JOIN_S" 8; then
		trace "join: no host found -- is the other handheld hosting, and on 2.4 GHz?"
		# 3 is slot's "no host" (RadioFail::NoHost), which it shows as a
		# waiting screen rather than an error. Any other code is a fault.
		return 3
	fi
	addr_set "$IFACE" "$LINK_PEER_IP"
	echo "$$" > "$MARK"
	trace "join: joined, ${LINK_PEER_IP%/*}"
	return 0
}

link_down() {
	trace "down"
	$WPA_CLI -p "$CTRL" -i "$IFACE" terminate >/dev/null 2>&1
	sleep 1
	addr_flush "$IFACE"
	rm -f "$CONF" "$MARK"
	rm -rf "$CTRL"
	# Give the network back if we took it. wifi-on.sh re-associates with the
	# user's own network and restarts udhcpc, which is what they had before
	# the link; without this, a link leaves the handheld off the network and
	# `task deploy` stops working until a reboot.
	if [ "$(cat "$PRIOR" 2>/dev/null)" = yes ] && ! pgrep wpa_supplicant >/dev/null 2>&1; then
		if [ -x "$ROOT/.allium/scripts/wifi-on.sh" ]; then
			trace "down: restoring the normal network"
			sh "$ROOT/.allium/scripts/wifi-on.sh" >/dev/null 2>&1 &
		fi
	fi
	rm -f "$PRIOR"
	return 0
}

# Cheap and often: slot warms the radio when a link-capable cart is seated, so
# this must not take the interface or disturb anything. Making wlan0 exist is
# the slow part of a link, and all this does.
link_warm() {
	trace "warm"
	radio_up || return 1
	return 0
}

case "${1:-} ${2:-}" in
"link host") link_host ;;
"link join") link_join ;;
"link down") link_down ;;
"link warm") link_warm ;;
"link cool") exit 0 ;;
*)
	echo "usage: slotlink.sh link [host|join|down|warm|cool]" >&2
	exit 2
	;;
esac
