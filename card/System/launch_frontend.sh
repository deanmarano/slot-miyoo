#!/bin/sh
# armv7 counterpart of upstream/slot/card/System/launch_frontend.sh.
#
# Two differences from upstream, both because this is a Miyoo and not an
# Anbernic H700:
#   - the loader is /lib/ld-linux-armhf.so.3, not ld-linux-aarch64.so.1
#   - the card root defaults to /mnt/SDCARD, the Miyoo path, not /mnt/sdcard
#
# As upstream does, slot is started *through the loader* rather than executed
# directly: FAT32 and exFAT cards are routinely mounted noexec, and handing the
# binary to ld.so as an argument sidesteps that.
#
# Upstream's led.sh and coresave.sh hooks are left out until the device is known
# to have the sysfs paths they poke; see notes/hardware.md.
SD="${SLOT_ROOT:-/mnt/SDCARD}"
SYS="$SD/System"
export SLOT_ROOT="$SD"

# Which Miyoo is this? Detected the way the stock boot hook does it
# (card/.tmp_update/updater), because that is the test the firmware itself
# trusts: 285 is the Mini Flip, 354 the Mini Plus, 283 the original Mini.
#
# This matters because two of the settings below are measured facts about the
# *Flip's* panel, not about the SoC, and applying them to another model would
# be inventing hardware facts. Override with SLOT_MIYOO_MODEL if the detection
# is ever wrong on a model nobody here has tested.
if [ -n "${SLOT_MIYOO_MODEL:-}" ]; then
	MODEL="$SLOT_MIYOO_MODEL"
elif [ -e /dev/input/event1 ]; then
	MODEL=285
elif [ -f /customer/app/axp_test ]; then
	MODEL=354
else
	MODEL=283
fi

# The Mini Flip's LCD is fitted upside down: a frame written top-down to
# /dev/fb0 appears inverted on the panel, confirmed on the device. No other
# model has been checked, so no other model gets the rotation -- a wrong
# rotation is an upside-down screen, which looks like a crash to anyone who
# has not read this comment. Set SLOT_FB_ROTATE=180 by hand to try it.
if [ "$MODEL" = 285 ]; then
	export SLOT_FB_ROTATE=180
fi

# The build's canvas is the Flip's 752x560 panel (OUT_W/OUT_H in
# crates/slot-gfx/src/surface.rs, set by patches/0002). The Mini and Mini Plus
# are 640x480, so this binary will not lay out correctly on them -- it is not
# a runtime setting yet. Say so in the log rather than drawing something wrong
# in silence; see notes/variants.md.
if [ "$MODEL" != 285 ]; then
	echo "slot: model $MODEL is not the Mini Flip (285) this build is sized for;" >&2
	echo "slot: the canvas is 752x560 and this panel is not. See notes/variants.md" >&2
fi

# Diagnostics, off by default because each writes a line per frame or per event
# to the card:
#   SLOT_TRACE_LATENCY=1  per-frame breakdown and the backend's own per-stage
#                         timings, into slot.log
#   SLOT_TRACE_INPUT=1    every input event and how it mapped, into
#                         input-trace.log, plus a survey of the input nodes
#   SLOT_TRACE=1          the audio ring every so often, as
#                         "queued/target, N dropped, M starved"
#
# All three are off now that the pacing is settled, and they are not free: each
# writes to the card from inside the frame loop, SLOT_TRACE_LATENCY once per
# frame and SLOT_TRACE_INPUT once per event. Turn on only the one being read.
#
# Two more that change behaviour rather than reporting it:
#   SLOT_FB_VSYNC=1       block in the page flip until the panel latches; off
#                         because slot paces itself and waiting here too cost
#                         most of the frame budget
#   SLOT_FB_PAGES=1       give up the page flip and draw at the scanout; this
#                         skips the driver's 6.6 ms page copy but tears, on the
#                         shelf and in game both, so it is not used
#   SLOT_DRIVE_EMU=0      stop chaining the core to the display's rate
#   SLOT_RING_FRAMES=N    audio ring depth in 60 Hz video frames, upstream's 8
#                         here; half of it is the DRC target, so 67 ms at
#                         48 kHz. Deeper is more audio latency
#   SLOTAO_FRAMES=N       MI_AO's hardware buffer, in 512-frame periods, 4 here
#                         = 43 ms. The other half of the latency

# The driver's FBIOPAN_DISPLAY costs 6.6 ms a frame here, which with 13.4 ms of
# real work puts the loop near 20 ms. Drawing straight at the scanout
# (SLOT_FB_PAGES=1) gives those 6.6 ms back but tears visibly, so the page flip
# stays. Instead the core is unchained from the display: it keeps its own
# 59.73 Hz and the display drops the frames it cannot fit, so the speed and the
# audio pitch are right and the cost is judder rather than slow motion.
export SLOT_DRIVE_EMU=0

# Audio: upstream's ring depth, and the codec queue throttle on by default in
# the binary (SLOTAO_QUEUE, five 512-frame periods, 53 ms).
#
# MI_AO ignores the buffer depth in its attributes -- asked for two periods it
# accepted 32, which is 341 ms -- and that was the audio lag. The throttle
# queries the queue instead and tops it up to a target, which held the whole
# pipeline at ~100 ms, measured. It used to make the sound choppy as well, and
# that turned out to be MI_AO_QueryChnStat answering in *bytes* where the
# throttle read periods: any audio at all counted as "5 or more", so it only
# wrote once the codec had run completely dry. notes/hardware.md has the
# numbers. SLOTAO_QUEUE=0 goes back to unthrottled and laggy if ever needed.
export SLOT_RING_FRAMES=8

# A cart that crashes its core soft-bricks the handheld: the seated cart is
# re-inserted on every boot, the core segfaults, slot dies before it can clear
# the cart, and since slot is the boot process there is no shelf to escape to.
# Kirby's Pinball Land DX does exactly this -- SIGSEGV in mGBA's _GBMBC2Read --
# and getting out of it needed FTP and a hand-edited Config/slot.state.
#
# So: drop a guard before launching and clear it once slot has survived a while.
# Finding it still there at boot means the last launch did not survive its first
# seconds, and the seated cart is the likeliest reason, so it is unseated and
# the handheld comes up on the shelf.
guard="$SD/Config/.slot-launching"
if [ -f "$guard" ]; then
	sed -i -e 's/^cart=.*/cart=/' -e 's/^cart_platform=.*/cart_platform=/' \
		"$SD/Config/slot.state" 2>/dev/null
	rm -f "$guard"
	echo "slot: last launch did not survive; unseated the cart" >> "$SD/slot-launch.txt"
fi
: > "$guard"
sync
# Long enough to be past loading a core and showing a frame, short enough that
# a deliberate power-off mid-game does not usually trip it -- and tripping it
# only costs starting at the shelf.
( sleep 25; rm -f "$guard" ) &

[ -f "$SD/slot.log" ] && mv -f "$SD/slot.log" "$SD/slot.log.1"

# NOTE: this used to stop Allium's daemon for the session, because alliumd owns
# the MENU button globally and draws a hotkeys overlay over the running game,
# which fights slot for the same button. That caused the handheld to shut down
# hard when launching a game, three times out of four, so it is reverted: a
# clumsy menu button is a far better problem than a device that cuts power.
#
# alliumd is PID 817-ish, started by /customer/main, and evidently something
# depends on it staying alive. If the overlay is worth another attempt, find out
# what notices its absence first -- do not just kill it again.
# Crash handling. slot's own handler prints the faulting pc and lr to the log
# (see patches/0001 for the armv7 register read); this adds the kernel side:
# upstream's coresave.sh writes the core, the process maps and a copy of the
# log into $SD/crash. Kept per-boot so a crash is still there after a restart.
mkdir -p "$SD/crash" 2>/dev/null
echo "|/bin/sh $SYS/coresave-miyoo.sh %p %s %e %t" > /proc/sys/kernel/core_pattern 2>/dev/null
ulimit -c unlimited 2>/dev/null

# Not exec: the exit status is worth recording. An unexplained shutdown looks
# the same as a clean exit from the outside, and this is what tells them apart.
started="$(date '+%F %T' 2>/dev/null)"
/lib/ld-linux-armhf.so.3 "$SYS/slot" > "$SD/slot.log" 2>&1
status=$?
echo "$started -> $(date '+%F %T' 2>/dev/null) exit=$status" >> "$SD/crash/exits.log"
if [ "$status" -gt 128 ]; then
	# 128 + signal: killed rather than returned. 139 is SIGSEGV, 134 SIGABRT.
	echo "  killed by signal $((status - 128)); see crash/ and slot.log.1" >> "$SD/crash/exits.log"
	cp -f "$SD/slot.log" "$SD/crash/slot-exit-$status.log" 2>/dev/null
fi
sync
