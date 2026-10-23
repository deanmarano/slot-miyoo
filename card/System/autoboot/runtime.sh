#!/bin/sh
# Boot straight into slot on Miyoo's own firmware.
#
# Not installed by default, and not shipped in .tmp_update, because that
# directory is how every launcher on this device boots: an Allium card already
# has its own runtime.sh there and this would replace it. Copy this file to
# /mnt/SDCARD/.tmp_update/runtime.sh by hand to turn autoboot on, delete it to
# get the launcher back -- both from any computer with the card in it, no shell
# and no telnet needed.
#
# runtime.sh is the hook that survives. Stock's /customer/main runs
# .tmp_update/updater once and then `rm -rf`s the directory, so an updater is
# an installer; a runtime.sh is run on every boot and left in place. Taking
# this branch also means stock never starts audioserver or keymon, which is
# what slot wants: audioserver owns MI_AO and slot's MI_AO_SetPubAttr comes
# back E_MI_ERR_NOT_PERM while it holds it.
ROOT=/mnt/SDCARD
# The firmware's payload on the card, which each handheld names after its own
# model: miyoo285 on the Mini Flip, miyoo354 on the Mini Plus, miyoo on the
# Mini. Found rather than assumed -- a card written for one of them would send
# the others to a directory that is not there, and the fallback below would be
# the only thing keeping the handheld usable.
CUSTOMER_DIR=/customer
for d in miyoo285 miyoo354 miyoo; do
	if [ -d "$ROOT/$d/app" ]; then
		CUSTOMER_DIR="$ROOT/$d"
		break
	fi
done
export LD_LIBRARY_PATH="/lib:/config/lib:$CUSTOMER_DIR/lib"

# The panel and the backlight, which stock brings up on the branch this
# replaces rather than before it. Without these the handheld boots black and
# looks dead.
cat /proc/ls
sleep 1
if [ ! -d /sys/class/pwm/pwmchip0/pwm0 ]; then
	echo 0 > /sys/class/pwm/pwmchip0/export
fi
echo 800 > /sys/class/pwm/pwmchip0/pwm0/period
echo 6 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle
echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable

# Relaunch rather than quit on a crash, as the Allium hook does and for the
# same reason, and bounded the same way: three quick deaths hands the handheld
# to stock's own UI instead of looping on a frontend that cannot start. A
# launch that lasted a minute resets the count -- that death is a fresh story.
tries=0
while [ "$tries" -lt 3 ]; do
	began=$(date +%s 2>/dev/null || echo 0)
	SLOT_ROOT="$ROOT" "$ROOT"/System/launch_frontend.sh
	ended=$(date +%s 2>/dev/null || echo 0)
	if [ "$((ended - began))" -ge 60 ]; then
		tries=0
	else
		tries=$((tries + 1))
		sleep 5
	fi
done

# Stock's UI, started the way main starts it. Returning from here puts us back
# in main's loop, which runs this script again.
cd "$CUSTOMER_DIR"/app 2>/dev/null || cd /customer/app 2>/dev/null || exit 0
exec ./MainUI
