#!/bin/sh
# Can this handheld do slot's two-player link, and in which role?
#
# slot's link is a TCP session on 10.42.0.1:7211 carrying mGBA's serial data.
# Getting there needs a private WiFi between the two handhelds, and that is all
# $root/System/slotlink.sh does. Upstream's version of that script assumes the
# Anbernic H700 radio: an AP on a *second* interface (wlan1), wpa_supplicant
# driving it through -Dnl80211, on 5745 MHz. This radio is an rtl8188fu --
# single interface, 2.4 GHz only, Realtek vendor driver -- so all three
# assumptions are in question and this script measures them rather than
# guessing.
#
# The questions, in the order that decides what we can build:
#   1. is there a wlan1 at all?          -> can we host the way upstream hosts?
#   2. does the driver speak nl80211?    -> is -Dnl80211 right, or -Dwext?
#   3. will wlan0 come up in AP mode?    -> can we host on one interface?
#   4. which frequencies can it use?     -> what channel can a link meet on?
# Joining needs none of this beyond a working station mode, which net-up.sh
# already proves, so a "no" everywhere still leaves the join role.
#
# Question 3 is settled by actually trying it, because nothing readable says
# whether a Realtek vendor driver will take mode=2 -- `wpa_supplicant -h`
# listing a driver is not the same as that driver doing AP.
#
# Busybox sh. Every tool is optional and a missing one is a real answer, so it
# prints "(absent)" and keeps going. It leaves the radio as it found it.
#
# usage: linkprobe.sh [card root]
# Results belong in notes/hardware.md, under a link heading.

root="${1:-/mnt/SDCARD}"
RUN=/tmp/slot-linkprobe
AP_CONF="$RUN/ap.conf"
AP_CTRL="$RUN/ap-ctrl"

say() { echo "$@"; }
rule() { say ""; say "== $* =="; }

have() { command -v "$1" >/dev/null 2>&1; }

# Report whether a tool is even on this card's firmware before any answer that
# depends on it, so "no" is never ambiguous between absent and refused.
tool() {
	if have "$1"; then
		say "$1: $(command -v "$1")"
	else
		say "$1: (absent)"
	fi
}

run() {
	printf '$ %s\n' "$*"
	"$@" 2>&1 || say "(failed: $?)"
}

show() {
	if [ -r "$1" ]; then
		printf '%s: ' "$1"
		cat "$1" 2>/dev/null || say "(unreadable)"
	else
		say "$1: (absent)"
	fi
}

say "slot link probe"
say "date: $(date 2>/dev/null)"
say "uptime: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
say "card root: $root"

rule "the tools slotlink.sh needs"
# Upstream's script calls exactly these. A missing `ip` or wpa_cli is fatal to
# both roles and worth knowing before anything else.
for t in wpa_supplicant wpa_cli ip ifconfig iwconfig iwlist iw hostapd rfkill udhcpc; do
	tool "$t"
done

rule "wpa_supplicant: version and the drivers it was built with"
# -Dnl80211 vs -Dwext is decided here. Realtek vendor builds are routinely
# wext-only, and upstream hardcodes nl80211.
if have wpa_supplicant; then
	run wpa_supplicant -v
	# -h lists the drivers compiled in; it exits non-zero on some builds, so
	# this is deliberately tolerant.
	wpa_supplicant -h 2>&1 | sed -n '/drivers:/,/^$/p' || say "(no driver list)"
else
	say "(absent -- neither role is possible without it)"
fi

rule "interfaces: is there a second one to host on?"
run ls /sys/class/net
for i in wlan0 wlan1 p2p0; do
	if [ -d "/sys/class/net/$i" ]; then
		say "$i: present"
		# phy80211 is the nl80211/cfg80211 marker. Its absence means a vendor
		# driver that only answers wireless extensions.
		if [ -e "/sys/class/net/$i/phy80211" ]; then
			say "  $i/phy80211: present -> cfg80211, so nl80211 should work"
		else
			say "  $i/phy80211: (absent) -> wext-only vendor driver, use -Dwext"
		fi
		show "/sys/class/net/$i/address"
	else
		say "$i: (absent)"
	fi
done

rule "driver module and its options"
# A Realtek concurrent build sometimes exposes a second vap through a module
# parameter, which would be the cheap way to get upstream's wlan1 host path.
run grep -iE '8188|8189|8723|8821|rtl|cfg80211' /proc/modules
for m in 8188fu rtl8188fu 8189fs 8723ds cfg80211; do
	if [ -d "/sys/module/$m/parameters" ]; then
		say "/sys/module/$m/parameters:"
		ls "/sys/module/$m/parameters" 2>&1 | sed 's/^/  /'
		# Concurrent/AP-ish knobs by name, since the useful ones vary by fork.
		for p in rtw_vap rtw_ap_mode concurrent rtw_country_code; do
			[ -r "/sys/module/$m/parameters/$p" ] && \
				say "  $p = $(cat "/sys/module/$m/parameters/$p" 2>/dev/null)"
		done
	fi
done

rule "nl80211 capabilities, if iw is here"
# The authoritative answer to "can it do AP" and "which bands", when present.
# Busybox has no iw, so expect this to be absent and fall through to the live
# test below.
if have iw; then
	run iw list
	run iw dev
else
	say "iw: (absent) -- capabilities not readable, see the live AP test"
fi

rule "frequencies the radio admits to"
# Whether 5 GHz is an option at all. Upstream meets on 5745; an 8188fu cannot,
# so a Miyoo link has to be told a 2.4 GHz channel.
if have iwlist; then
	run iwlist wlan0 freq
else
	say "iwlist: (absent)"
fi

rule "current state, so this can be put back"
run ifconfig wlan0
if have wpa_cli; then
	run wpa_cli -i wlan0 status
fi
was_supplicant=no
pgrep wpa_supplicant >/dev/null 2>&1 && was_supplicant=yes
say "wpa_supplicant running beforehand: $was_supplicant"

rule "the live test: will wlan0 take mode=2 (AP)?"
# The decisive one. Everything above is readable claims; this is the radio
# answering. A pass means slot can host a link on this handheld with a
# single-interface slotlink.sh; a fail means this device joins and the Anbernic
# hosts, which is still a playable link.
#
# It runs on its own ctrl_interface in /tmp and is torn down afterwards, so it
# cannot disturb the supplicant Allium is running on wlan0 -- beyond taking the
# interface for the duration, which the teardown gives back.
if ! have wpa_supplicant || [ ! -d /sys/class/net/wlan0 ]; then
	say "skipped: no wpa_supplicant or no wlan0"
else
	rm -rf "$RUN"
	mkdir -p "$AP_CTRL"
	{
		echo "ctrl_interface=$AP_CTRL"
		echo 'ap_scan=2'
		echo 'network={'
		echo '	ssid="slotlink-probe"'
		echo '	mode=2'
		# 2437 = channel 6. Deliberately not upstream's 5745: the point is to
		# test AP mode, and picking a band this radio cannot do would fail for
		# the wrong reason and prove nothing.
		echo '	frequency=2437'
		echo '	key_mgmt=WPA-PSK'
		echo '	proto=RSN'
		echo '	pairwise=CCMP'
		echo '	psk="slotlink0"'
		echo '}'
	} > "$AP_CONF"
	chmod 600 "$AP_CONF"

	# Both drivers, because which one this build has is exactly what is in
	# question. First to reach COMPLETED wins and is the answer.
	for drv in nl80211 wext; do
		say ""
		say "-- trying -D$drv on wlan0 --"
		# Stop anything of ours from the previous iteration.
		wpa_cli -p "$AP_CTRL" -i wlan0 terminate >/dev/null 2>&1
		sleep 1
		ip link set wlan0 up 2>/dev/null || ifconfig wlan0 up 2>/dev/null
		if wpa_supplicant -B -i wlan0 -c "$AP_CONF" -D"$drv" 2>&1 | sed 's/^/   /'; then
			say "   started"
		else
			say "   would not start with -D$drv"
			continue
		fi
		# Up to 10 s, reporting each state change: an AP that works reaches
		# COMPLETED within a second or two, and a driver that refuses mode=2
		# usually says so immediately rather than sitting in SCANNING.
		n=0
		last=
		state=
		while [ "$n" -lt 20 ]; do
			state=$(wpa_cli -p "$AP_CTRL" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
			if [ "$state" != "$last" ]; then
				say "   ${n}: ${state:-no answer}"
				last="$state"
			fi
			[ "$state" = COMPLETED ] && break
			n=$((n + 1))
			sleep 0.5 2>/dev/null || sleep 1
		done
		if [ "$state" = COMPLETED ]; then
			say "   AP UP with -D$drv  <= this handheld can host"
			run wpa_cli -p "$AP_CTRL" -i wlan0 status
			run iwconfig wlan0
		else
			say "   no AP with -D$drv (last state: ${state:-none})"
		fi
		wpa_cli -p "$AP_CTRL" -i wlan0 terminate >/dev/null 2>&1
		sleep 1
		[ "$state" = COMPLETED ] && break
	done

	rule "driver messages from the attempt"
	if have dmesg; then
		dmesg 2>&1 | grep -iE '8188|rtl|wlan|ap mode|hostapd|softap' | tail -20
	else
		say "dmesg: (absent)"
	fi

	rule "putting the radio back"
	# Leave it as found. Allium's wifi-on.sh is idempotent and is the thing
	# that knows how this chip wants to be started, so hand back to it rather
	# than reconstructing a station config here.
	ip addr flush dev wlan0 2>/dev/null || true
	rm -rf "$RUN"
	if [ "$was_supplicant" = yes ] && ! pgrep wpa_supplicant >/dev/null 2>&1; then
		if [ -x "$root/.allium/scripts/wifi-on.sh" ]; then
			say "restarting the radio through Allium's wifi-on.sh"
			sh "$root/.allium/scripts/wifi-on.sh" >/dev/null 2>&1
			sleep 2
		else
			say "wifi was running before this and is not now, and there is no"
			say "wifi-on.sh to restore it -- reboot to get the network back"
		fi
	fi
	run ifconfig wlan0
fi

rule "verdict"
# Spelled out, because the whole point is to come back to one answer.
say "join role  (this device connects to the Anbernic's link AP):"
say "  needs station mode, which net-up.sh already proves works -> expected yes"
say "host role  (the Anbernic connects to this device):"
say "  needs the live AP test above to say \"AP UP\". Read it."
say ""
say "if hosting works, slotlink.sh hosts on wlan0 with the driver that passed,"
say "on a 2.4 GHz channel. if it does not, this handheld takes the join role"
say "and the Anbernic hosts -- which still plays, it just decides who starts."
