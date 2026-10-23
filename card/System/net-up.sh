#!/bin/sh
# Bring the handheld onto the network: WiFi, then telnet and FTP of the card.
#
# Used from two places: the "slot net" app, and the boot hook when slot is
# booted instead of Allium. In that second case there is no alliumd to do it,
# and losing the network would mean going back to carrying the SD card between
# machines, so this runs in the background at boot.
#
# It deliberately does not call Allium's telnet-on.sh/ftp-on.sh: both begin with
# wait-for-wifi.sh, which pings 1.1.1.1 once a second for up to sixty seconds,
# and calling the pair after waiting once meant minutes of an apparently frozen
# handheld. A LAN address is all that is needed, so it waits for one and starts
# the daemons directly.
#
# usage: net-up.sh [card root] [log file]
root="${1:-/mnt/SDCARD}"
out="${2:-$root/slot-net.txt}"
scripts="$root/.allium/scripts"
conf=/appconfigs/wpa_supplicant.conf

log() { echo "$@" >> "$out"; }

# The vendor's radio tools are not on PATH when slot is the boot process.
# Allium's hook exported its own bin directory; stock's does not, and
# wpa_supplicant lives in the firmware payload on the card -- miyoo354/app on
# a Mini Plus, miyoo285 on a Flip, miyoo on a Mini -- or in /customer/app.
# Calling it bare found nothing and the radio never associated, with no error
# anywhere a person would look.
find_tool() {
	name=$1
	if command -v "$name" > /dev/null 2>&1; then
		echo "$name"
		return
	fi
	for d in "$root"/miyoo285/app "$root"/miyoo354/app "$root"/miyoo/app /customer/app; do
		if [ -x "$d/$name" ]; then
			echo "$d/$name"
			return
		fi
	done
	echo "$name"
}

: > "$out"
log "slot net — $(date 2>/dev/null)"
log ""

# Credentials from the card, if given. Allium's on-screen keyboard has no shift
# key, so a network name with capitals cannot be typed on the handheld at all,
# and SSIDs are case-sensitive.
creds="$root/slot-wifi.txt"
if [ -r "$creds" ]; then
	real=$(grep -v '^[[:space:]]*#' "$creds" | grep -v '^[[:space:]]*$')
	ssid=$(echo "$real" | sed -n '1p' | tr -d '\r')
	psk=$(echo "$real" | sed -n '2p' | tr -d '\r')
	if [ -n "$ssid" ]; then
		mkdir -p /appconfigs 2>/dev/null
		{
			echo "ctrl_interface=/var/run/wpa_supplicant"
			echo "update_config=1"
			echo "network={"
			echo "	ssid=\"$ssid\""
			if [ -n "$psk" ]; then
				echo "	psk=\"$psk\""
			else
				echo "	key_mgmt=NONE"
			fi
			echo "}"
		} > "$conf"
		log "wrote $conf for \"$ssid\""
	fi
fi

# Keep trying, rather than giving up. The first version made one attempt and
# waited 45 s, which is enough when the radio is already associated but not from
# a cold boot -- and when slot is the boot process there is no Allium menu to
# run this from by hand, so a single failure means fetching the SD card. An
# attempt costs nothing while it is idle, so it retries for as long as it takes.
# How early this runs matters: at boot the radio may not be ready when
# wifi-on.sh insmods the driver, which would explain cold boots failing while
# the same script works by hand from a menu later on.
log "uptime at start: $(cut -d" " -f1 /proc/uptime 2>/dev/null)s"
# Ask for a little CPU before anything else, best effort.
#
# Booting straight into slot puts this association next to slot's heaviest
# moment -- core load, PNG decoding, cart faces on two workers -- on two
# Cortex-A7s, and slot's threads are the ones with priority: emu at -8, audio
# and input at -10, while wpa_supplicant, the driver insmod and udhcpc sit at
# 0. The four-way handshake has timeouts, and a handshake dropped from cold is
# what this card keeps showing; under Allium the same association happens
# beside an idle launcher.
#
# renice on $$ rather than `nice` on the command: busybox nice does not run
# the command at all when setpriority is refused, which in a boot script would
# mean no network whenever this is not root. This way a refusal costs nothing
# and the children -- wifi-on.sh, udhcpc, wpa_supplicant -- inherit it when it
# works.
renice -n -5 $$ > /dev/null 2>&1 || true

log "wpa_supplicant: $(find_tool wpa_supplicant)"
log "wpa_cli:        $(find_tool wpa_cli)"
log "credentials:    $([ -r "$creds" ] && echo "$creds" || echo "(none -- using whatever /appconfigs already holds)")"
log "wlan0 before wifi-on: $(ifconfig wlan0 > /dev/null 2>&1 && echo present || echo absent)"
log "module before wifi-on: $(grep -c 8188fu /proc/modules 2>/dev/null)"
log ""

# Measured on the device: the retry loop used to call wifi-on.sh on *every*
# attempt, and wifi-on.sh tears the chip down -- "rtl8188fu_hal_deinit",
# "CardDisableRTL8188FU" in the driver messages. Three attempts logged
# wpa_state SCANNING, then ASSOCIATING, then 4WAY_HANDSHAKE: it was getting
# further each time and being reset before it could finish. So the radio is
# only brought up when it is actually down, and an attempt that is making
# progress is left to make it.
attempt=1
while :; do
	if ! ifconfig wlan0 > /dev/null 2>&1 || ! pgrep wpa_supplicant > /dev/null 2>&1; then
		if [ -x "$scripts/wifi-on.sh" ]; then
			sh "$scripts/wifi-on.sh" > /dev/null 2>&1
		else
			# No Allium on this card, so bring the radio up the way the
			# firmware does. Stock's /customer/main already insmods
			# 8188fu.ko from the card root when it mounts, so the module is
			# usually there and this is the interface and the supplicant;
			# the insmod is kept for the case where it is not.
			grep -q 8188fu /proc/modules 2>/dev/null ||
				insmod "$root/8188fu.ko" > /dev/null 2>&1
			# Power the radio's rail before expecting an interface. The
			# driver registers without it -- "usbcore: registered new
			# interface driver rtl8188fu" in the kernel log -- and wlan0
			# never appears, which is what a Mini Plus showed for two boots:
			# module loaded, wlan0 ABSENT, supplicant with nothing to attach
			# to. Allium's wifi-on.sh does the same call, and so does stock's
			# own MainUI.
			wifion=$(find_tool axp_test)
			if [ -x "$wifion" ] || command -v axp_test > /dev/null 2>&1; then
				"$wifion" wifion > /dev/null 2>&1
				sleep 2
				log "powered the radio with $wifion wifion"
			else
				log "no axp_test: the radio's rail is whatever the firmware left it"
			fi
			ifconfig wlan0 up > /dev/null 2>&1
			pgrep wpa_supplicant > /dev/null 2>&1 ||
				"$(find_tool wpa_supplicant)" -B -D nl80211 -i wlan0 -c "$conf" \
					> /dev/null 2>&1
		fi
		log "attempt $attempt at $(cut -d" " -f1 /proc/uptime 2>/dev/null)s: brought the radio up, wlan0 $(ifconfig wlan0 > /dev/null 2>&1 && echo present || echo ABSENT), module $(grep -c 8188fu /proc/modules 2>/dev/null)"
	else
		# Already up and supplicant running: nudge it rather than reset it.
		"$(find_tool wpa_cli)" -i wlan0 reassociate > /dev/null 2>&1
		log "attempt $attempt at $(cut -d" " -f1 /proc/uptime 2>/dev/null)s: radio already up, reassociating"
	fi

	# Association first: it and DHCP fail for different reasons. 90 s, not 45:
	# a 4-way handshake from cold was still in progress when the old limit cut
	# it off. Each state change is logged, so a capture shows the progression
	# rather than just where it happened to be when the clock ran out.
	assoc=""
	n=0
	last=""
	drops=0
	while [ $n -lt 90 ]; do
		state=$("$(find_tool wpa_cli)" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
		if [ "$state" != "$last" ]; then
			log "    ${n}s: ${state:-unknown}"
			# 4WAY_HANDSHAKE falling back to scanning is also what this radio
			# does on the way to a *successful* connect: two drops and a
			# COMPLETED around 50 s is the normal cold-boot progression here.
			# So count them, and only point at the key once that has stopped
			# being the likeliest explanation. The old message said "check the
			# key" on the first drop, and a correct key was duly checked and
			# re-entered while the real answer was to wait another minute.
			case "$last:$state" in
				4WAY_HANDSHAKE:SCANNING|4WAY_HANDSHAKE:DISCONNECTED)
					drops=$((drops + 1))
					if [ "$drops" -ge 4 ]; then
						log "    handshake dropped ${drops}x -- now worth checking the key in slot-wifi.txt"
					else
						log "    handshake dropped (${drops}) -- normal from cold, still trying"
					fi ;;
			esac
			last="$state"
		fi
		[ "$state" = "COMPLETED" ] && assoc=1 && break
		# Only as a fallback, where wpa_cli says nothing at all: a configured
		# ESSID shows up here before the handshake finishes, so trusting it
		# while the supplicant is mid-connect declares success too early.
		if [ -z "$state" ]; then
			essid=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p')
			[ -n "$essid" ] && assoc=1 && break
		fi
		n=$((n + 1))
		sleep 1
	done

	# wifi-on.sh starts udhcpc before the link is up, so that attempt has
	# already given up by now; ask again.
	addr=""
	if [ -n "$assoc" ]; then
		udhcpc -i wlan0 -n -q -t 5 -T 2 -s /etc/init.d/udhcpc.script > /dev/null 2>&1
		m=0
		while [ $m -lt 20 ]; do
			addr=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
			[ -n "$addr" ] && break
			m=$((m + 1))
			sleep 1
		done
	fi

	if [ -n "$addr" ]; then
		log "attempt $attempt: associated, address $addr"
		break
	fi

	log "  ${assoc:+associated but no lease}${assoc:-no association} after ${n}s"
	log "  supplicant: $(pgrep wpa_supplicant > /dev/null 2>&1 && echo running || echo NOT running)"
	log "  wpa_state: $("$(find_tool wpa_cli)" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')"
	# Only on the first two attempts, so the file stays readable: is the network
	# even visible? This radio is 2.4 GHz only.
	if [ "$attempt" -le 2 ]; then
		log "  config: $(wc -c < "$conf" 2>/dev/null || echo 0) bytes"
		log "  networks in range:"
		iwlist wlan0 scan 2>/dev/null | sed -n 's/.*ESSID:"\(.*\)"/    \1/p' | sort -u | head -12 >> "$out"
		log "  driver messages:"
		dmesg 2>/dev/null | grep -iE "8188|wlan|wifi" | tail -6 >> "$out"
	fi
	sync
	attempt=$((attempt + 1))
	sleep 15
done

# setsid so they outlive whatever started this.
pgrep telnetd > /dev/null 2>&1 || setsid telnetd -l sh > /dev/null 2>&1 || telnetd -l sh > /dev/null 2>&1
# tcpsvd is the listener; ftpd is only spawned per connection, so looking for
# ftpd reports "down" while FTP is serving perfectly well.
pgrep tcpsvd > /dev/null 2>&1 || setsid tcpsvd -E 0.0.0.0 21 ftpd -w "$root" > /dev/null 2>&1 &
sleep 1
log "telnet: $(pgrep telnetd > /dev/null 2>&1 && echo up || echo down)"
log "ftp:    $(pgrep tcpsvd > /dev/null 2>&1 && echo up || echo down)"
log ""
log "on the computer:  export SLOT_DEVICE=$addr"
sync

# Stay on the network, rather than only getting onto it once.
#
# Everything above runs once and exits, which is fine until the radio drops --
# and it drops whenever the handheld naps, which cost most of a working day in
# "the device is off the network" when it was simply asleep and nothing
# re-associated. Allium had no watchdog either; it just happened to be running
# a menu that someone could pick "wifi on" from. When slot is the boot process
# there is no such menu.
#
# A poll every WATCH_EVERY seconds: one wpa_cli call, nothing while the link is
# up. On a drop it reassociates first, because that is what the radio usually
# needs, and only brings the whole chip up again if that has failed twice --
# the same lesson as the attempt loop above, where tearing the chip down on
# every retry stopped a connection that was making progress.
WATCH_EVERY=20
WATCH_LOG_MAX=65536

watch_log() {
	# Bounded, because this runs for as long as the handheld is on.
	[ "$(wc -c < "$out" 2>/dev/null || echo 0)" -gt "$WATCH_LOG_MAX" ] && : > "$out"
	log "$@"
}

link_up() {
	[ "$("$(find_tool wpa_cli)" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')" = "COMPLETED" ] &&
		[ -n "$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')" ]
}

# One watchdog, however many times this script is run: the "slot net" app and
# the boot hook both call it, and two of these would fight over the radio.
pidfile=/var/run/slot-netwatch.pid
if [ -r "$pidfile" ] && [ -d "/proc/$(cat "$pidfile" 2>/dev/null)" ]; then
	log "watchdog: already running as $(cat "$pidfile")"
	exit 0
fi

watchdog() {
	echo $$ > "$pidfile"
	lost=0
	while :; do
		sleep "$WATCH_EVERY"
		if link_up; then
			if [ "$lost" -gt 0 ]; then
				watch_log "watchdog: back at $(cut -d" " -f1 /proc/uptime 2>/dev/null)s, address $(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')"
				lost=0
			fi
			# The daemons are cheap to check and have been seen to die with a
			# session; FTP reports through tcpsvd, not ftpd, which is spawned
			# per connection.
			pgrep telnetd > /dev/null 2>&1 || setsid telnetd -l sh > /dev/null 2>&1
			pgrep tcpsvd > /dev/null 2>&1 || setsid tcpsvd -E 0.0.0.0 21 ftpd -w "$root" > /dev/null 2>&1 &
			continue
		fi
		lost=$((lost + 1))
		[ "$lost" = 1 ] && watch_log "watchdog: link lost at $(cut -d" " -f1 /proc/uptime 2>/dev/null)s"
		if [ "$lost" -le 2 ]; then
			"$(find_tool wpa_cli)" -i wlan0 reassociate > /dev/null 2>&1
		else
			[ -x "$scripts/wifi-on.sh" ] && sh "$scripts/wifi-on.sh" > /dev/null 2>&1
			watch_log "watchdog: reassociate did not take, brought the radio up again"
		fi
		# Give the supplicant a moment, then ask for a lease: wifi-on.sh runs
		# udhcpc before the link is up, same as on a cold boot.
		sleep 5
		link_up ||
			udhcpc -i wlan0 -n -q -t 5 -T 2 -s /etc/init.d/udhcpc.script > /dev/null 2>&1
	done
}

# Backgrounded, not setsid'd: the boot hook already starts this script with
# setsid, so the watchdog is orphaned to init when this exits and keeps going.
# Run from the "slot net" app instead, it lives as long as Allium lets the app
# live -- and there the menu is right there to run again.
watchdog &
log "watchdog: polling every ${WATCH_EVERY}s"
sync
