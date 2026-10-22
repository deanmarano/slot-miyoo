# Miyoo Mini Flip — measured facts

From `card/System/probe.sh` run on the device on **2026-10-12**, firmware as
shipped on Dean's Allium card. Raw report and `slot.log` are in `device-dump/`
(gitignored). Everything here is measured, not inferred; spec-sheet claims that
turned out wrong are called out.

## Verdict

**The armv7 build runs on the device.** `slot --init-root` completed with exit 0
and created the content root; a normal start gets through boot, reads the panel,
and stops at exactly one thing:

```
slot: boot: start at 0.0 ms
slot: fb0 hint 752x560
slot: gl context: libEGL.so: cannot open shared object file: No such file or directory
```

So the toolchain, libc, loader and binary are all correct. The only blocker is
the renderer, as expected.

## Core facts

| | measured | note |
|---|---|---|
| kernel | Linux 4.9.84 SMP PREEMPT, `armv7l` | built 2025-09-02 |
| CPU | 2x ARMv7 rev 5, CPU part **0xc07** | Cortex-A7, as expected |
| CPU features | `neon vfpv4 idiva idivt vfpd32 lpae thumbee` | matches our `-march=armv7ve -mfpu=neon-vfpv4` |
| **RAM total** | **103352 kB (~101 MB)** | **not 128 MB** — the rest is reserved for the SoC |
| RAM available | 81632 kB at idle, no swap | the real ceiling to design against |
| **glibc** | **2.28** (A-profile 8.2-2018-08, gcc 8.2.1) | our build needs <= 2.28 — exact match |
| loader | `/lib/ld-linux-armhf.so.3` | what both launch scripts use |
| card root | `/mnt/SDCARD`, `/dev/mmcblk0p1` | confirmed |
| card mount | `vfat rw,dirsync,relatime,fmask=0000` | **not** `noexec`; files are +x |
| rootfs | squashfs, read-only; `/tmp`, `/var` tmpfs | only the card is writable |

## Panel — `/sys/class/graphics/fb0`, "MStar FB0"

| attr | value |
|---|---|
| `virtual_size` | `752,1680` |
| `modes` | `U:752x560p-76`, `U:752x560p-210` |
| `bits_per_pixel` | `32` |
| `stride` | `3008` (= 752 x 4) |
| `rotate` | `0` |

Three things follow, and they are better than assumed:

1. **The panel is 752x560, not the 750x560 the spec sheets claim.** 752 is also
   conveniently a multiple of 16.
2. `virtual_size` height 1680 is **3 x 560**: the framebuffer is already
   **triple-buffered**, so the software `Surface` can page-flip with
   `FBIOPAN_DISPLAY` instead of tearing or blitting through a shadow buffer.
3. **32 bpp and no rotation needed** — no `SLOT_ROTATE` equivalent required, and
   no 16-bit packing in the rasteriser.

Against slot's `OUT_W`/`OUT_H` of 720x480 and `SCALE = 3` over a 240x160 source:
752x560 fits a **3x** GBA image (720x480) with a 16px side and 40px top/bottom
border, which is close to upstream's own geometry. That is the layout to aim at.

## No 3D, but a 2D blitter and an audio API

```
no EGL/GLES/Mali libraries anywhere on the usual paths
```

Confirmed absent. What *is* there, in **`/config/lib`** (a read-only squashfs):

```
libmi_gfx.so    libmi_disp.so   libmi_panel.so  libmi_sys.so
libmi_ao.so     libmi_ai.so     libmi_common.so libcam_os_wrapper.so
libmi_divp.so   libmi_ipu.so    libmi_sed.so    libmi_vdec.so
libmi_venc.so   libmi_wlan.so
```

- `libmi_gfx.so` — the SigmaStar 2D blitter. Candidate for hardware-accelerating
  the blit and scale once a CPU rasteriser works.
- `libmi_ao.so` — audio out, used by Allium via FFI.
- **MI_AO cannot resample from the Game Boy's rate.** Its sample-rate enum is
  literal Hz — 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
  96000 — with no 32768. `MI_AO_EnableReSmp` takes the same enum, so handing the
  hardware resampler the core's rate is not possible; 32000 would be 2.4% out,
  which is an audible pitch and speed error. The software resample in `emu.rs`
  stays.
- **Audio works through MI_AO.** Game sound and slot's own cartridge effects,
  no clicking. The cost is real: with audio dead the pacer reported work well
  under the period, and with it running it is **15.5 ms against 16.76 ms** —
  zero frames missed, but about 1 ms of headroom, which is why it feels shaky.
- **MI_AO is the path that works, and the audio server owns it.** The vendor
  stack goes through MI_AO, and with the server running slot's
  `MI_AO_SetPubAttr` returns `0xa0052009` — decoded with the SDK's own macro
  (`MI_ERR_ID | module<<16 | level<<12 | errid`) that is errid 9,
  `E_MI_ERR_NOT_PERM`, "try to change static attribute". Only one of them can
  configure the device, so the boot hook skips the server when `.slot-boot` is
  set.
- **The click every three seconds was not the server's absence.** It was slot's
  ALSA sink: `RELEASE_AFTER` drops the device after three seconds of silence and
  the amplifier pops each time it reopens. The MI_AO sink never releases.
- **The driver leaks `ERESTARTSYS`.** `snd_pcm_writei` and `snd_pcm_recover`
  both return `-512` when a signal interrupts them, which `snd_strerror` renders
  as "Unknown error 512". It is kernel-internal and should never reach
  userspace. Treating it as fatal killed the sink on its first write and the
  ring then overflowed — 417,000 samples dropped in a session, heard as a pop
  every second or two. Both calls retry it now.
- **ALSA runs at 48 kHz and has `plug`, but it cannot resample to 32768.** `plug:default` and
  `plughw:0,0` do not open at all, so there is no resampling plugin to fall back
  on, and `hw:0,0` rejects the core's 32768 Hz outright: "Rate doesn't match
  (requested 32768Hz, get 48000Hz)". `patches/0005` opens at a rate the hardware
  takes and tells the ring, which is all that was needed, since `emu.rs` already
  resamples the core's output to whatever rate the ring reports.
- **The audio server has to be off.** The boot hook starts one to suppress a pop
  on open, and it holds the PCM, which is why slot's sink reported "Device or
  resource busy". Skipped when `.slot-boot` is set.
- **ALSA does exist**, contrary to what I first concluded. The qemu container had
  no `libasound.so`, and I wrongly generalised that to the device. On hardware
  slot's ALSA sink loads and gets as far as `hw:0,0: Device or resource busy`,
  so the library and the PCM are both there and something else was holding the
  device. An `MI_AO` sink may still be wanted, but it is not forced.

## The handheld's address moves, and it is not on this machine's subnet

It was 192.168.1.135 for a whole session and then came up on **192.168.1.145**.
DHCP, and nothing pins it. An evening ended with "the device is off the
network" when it was simply answering somewhere else.

Two things made that worse than it needed to be:

- A port sweep of 192.168.1.0/24 from the build host found nothing and looked
  conclusive. **This machine is on 10.200.0.0/24** and reaches the handheld
  through a router, so every probe timed out rather than being refused, and a
  silent sweep means nothing there. `task device:find` now takes the subnet
  from `SLOT_DEVICE` instead of the local link.
- `net-up.sh` already writes the address it got into `slot-net.txt` at the card
  root, with a ready-made `export SLOT_DEVICE=...` line. That file is the
  answer whenever the handheld seems missing, and it is readable from the Mac
  with the card in it even when nothing is on the network.

### WiFi: the retry recovers now, but the radio is still flaky

```
0s DISCONNECTED -> 2s ASSOCIATING -> 3s 4WAY_HANDSHAKE -> 8s SCANNING   (dropped)
19s ASSOCIATING -> 20s 4WAY_HANDSHAKE -> 25s SCANNING                   (dropped)
49s ASSOCIATING -> 50s COMPLETED
```

Two dropped four-way handshakes and then success, 50 s from a cold boot. The
old retry loop called `wifi-on.sh` every attempt and tore the chip down, so a
boot like this one could never finish; leaving an attempt in progress alone is
what lets it through. One success earlier was not proof -- this is the first
boot that showed the failure and the recovery in the same log.

## MI_AO ignores `u32FrmNum`: the codec holds 341 ms unless you hold it down

Measured by filling it -- writes return while there is room and block when
there is not, so the periods accepted before the first slow write are the
depth:

```
slot: audio: MI_AO took 33 periods of 512 before blocking, 352 ms of hardware buffer
```

**Asked for two periods. Got thirty-three.** (Thirty-two of queue plus the one
in flight: `QueryChnStat` later put `u32ChnTotalNum` at 65536 bytes, exactly 32
periods, 341 ms. The two measurements agree.) `MI_AUDIO_Attr_t.u32FrmNum` is
advisory at best on this stack, so any latency figure computed from it is
fiction. And `Ring::fill` pads with silence rather than waiting, so the sink
races ahead and keeps all 341 ms of it full: that is the sound running behind
the picture, and it is most of what the "starved" counter counts.

A whole evening of latency tuning went into the half of the budget that was
visible -- the ring's DRC target, cut from 100 ms to 33 -- while this sat
underneath unmeasured. The tell was there: 67 ms of real reduction that nobody
could hear.

`MI_AO_QueryChnStat` gives `u32ChnTotalNum` / `u32ChnFreeNum` / `u32ChnBusyNum`,
and busy is the queue -- **in bytes**, see below. The sink writes only while it
is under `SLOTAO_QUEUE` periods (5, about 53 ms) and lets the codec drain
otherwise, which puts the depth back under our control.

**The lesson, again: on this device, measure the buffer, do not configure it.**

### `MI_AO_QueryChnStat` answers in bytes, which is where the 43,008 came from

`SLOTAO_QUEUE=N` holds the queue at N periods and does what it is meant to: the
lag goes and the sound sits with the picture. For a while it also made the sound
choppy, and the throughput pinned at **43,008 frames a second** against the
48,000 the codec is configured for. That number was read as the codec draining
10% slow. It was not; it was a unit mismatch in our own code.

**The counts are bytes.** Logged on the device (2026-10-14, the counters are in
the sink's 5 s trace):

```
slot: audio: codec chan total 65536 free 57216 busy 8320
```

`u32ChnTotalNum` is **65536 bytes** -- 32 periods of 2048 (512 frames, stereo,
16-bit), **341 ms**, which is the depth `u32FrmNum` asked for 2 of and got 32
of. Busy counts of 8320, 2560 and 648 are 4.06, 1.25 and 0.32 periods, so they
are plainly not a period count.

`slotao_queued()` returned that byte count and the throttle compared it against
`SLOTAO_QUEUE` **as periods**. Any audio at all in the codec is "5 or more", so
the throttle only wrote once the queue had run completely dry, then dumped the
whole target in one burst. A sawtooth from 53 ms to zero every 59.5 ms:

```
53.3 ms of audio per burst / (53.3 + ~6 ms before a pass notices) = 89.6%
48000 x 0.896 = 43,008
```

The ~6 ms is a pass noticing on the next 10 ms tick -- `CONFIG_HZ` is 100 -- so
the arithmetic ties the figure to this kernel's tick, not to the codec. It was
stable to four figures because the duty cycle is.

Measured with the bug in place, at `SLOTAO_QUEUE=5`, 512-frame periods:

| | |
|---|---|
| throughput | 43,008 frames/s (420 periods per 5 s, in bursts of 5) |
| codec queue floor | 0 bytes, every window |
| passes | 100/s, exactly -- the loop's cadence was never the problem |
| ring | 4000-6400 against a 3200 target, `0 starved` |
| core stalls | 2,888 and climbing |

And after converting the byte count to frames and throttling on those:

| | |
|---|---|
| throughput | **48,036 frames/s** |
| codec queue floor | 1704-1776 frames of 2560, i.e. 35 ms of its 53 |
| ring | 1748-2905, on its target |
| core stalls | **0** |
| dropped / starved / send errors | 0 / 0 / 0 |
| latency | ~47 ms in the codec + ~52 ms in the ring, about 100 ms, from ~420 |

Confirmed by ear on the handheld: no lag, no chop. So the throttle is **on by
default** at five periods, and `SLOTAO_QUEUE=0` restores the unthrottled path.

Fast-forward is the one transient left: `FfStart` drives the ring down to
~150 frames with a few hundred "ring short" passes in that window, and the
throttle correctly declines to write what the ring cannot fill rather than
padding silence. Output stays at 48,137 frames/s through it, `0 starved`, and
it recovers within two windows.

Ruled out along the way, and still ruled out:

- **the audio thread starving the core** -- sleeping every pass instead of only
  the empty ones changed nothing;
- **the ring being too shallow** -- it reported 0 starved throughout; the
  deficit was downstream of it, which is what made the ring numbers misleading
  for most of an evening;
- **the rate enum** -- `MI_AUDIO_SampleRate_e` is literal Hz
  (`E_MI_AUDIO_SAMPLE_RATE_48000 = 48000`), so 48000 is valid and is what is
  set. The codec's pitch was always correct, which should have been taken as
  proof it really did consume 48,000 frames a second.

What was *wrongly* ruled out, and the lesson in it: **write cadence**, on the
grounds that changing the period size 512 -> 128 left the frames/s identical. An
identical figure across a 4x granularity change is not an exoneration, it is a
clue that the mechanism is indifferent to granularity -- which a duty cycle set
by the 10 ms tick is. The test was run, the result was recorded correctly, and
the inference went the wrong way for a session.

`PERIOD_FRAMES` is 512. 128 existed only to give the throttle granularity it did
not need.

## Overwriting a dlopen'ed library under a running slot is a crash

`crash/exits.log` had 16 crashes in one evening, 15 of them SIGSEGV or SIGBUS in
`slot-audio-miao`, each one minutes after a deploy. They were not an audio bug.
`task deploy` staged the main binary as `slot.new` and renamed it -- FTP
truncates on open, and a rename is atomic -- but pushed `libslotao.so` straight
over the live file, which the audio thread has `dlopen`ed and mapped. Truncating
a mapped file under a running process is SIGBUS in whichever thread touches the
missing pages.

The shim and both cores are now staged and renamed like the binary. The signal
to notice sooner: a crash *thread* that matches whatever was just deployed, and
a crash *time* that matches the deploy rather than anything the user did.

## mGBA used to crash on an MBC2 cart: a use-after-free in the core (fixed)

```
SIGSEGV in thread slot-emu, Kirby's Pinball Land DX (GBC)
pc mgba_libretro.so+0x491c8  _GBMBC2Read
lr mgba_libretro.so+0x4c6a0  GBLoad8
```

0.9 s after the first frame, reproducible on that cart. Fixed by
`cores/mgba/patches/gb-mbc2-sram-bank.patch`; the cart plays and no new entry
has appeared in `crash/exits.log` since (2026-10-14).

The cart header is innocent: type `0x06`, MBC2+BATTERY, RAM size byte `0x00`,
which is what the spec requires for MBC2 because its 512x4 bits of RAM live
inside the mapper rather than in a RAM chip. `GBMBCInit` duly sets
`sramSize = 0x100`.

That is smaller than the 8 KB bank size `GBMBCSwitchSramBank` is written
around, so every path through its bounds check failed and it returned **without
assigning `sramBank`**. `GBLoadSave` reaches it immediately after
`GBSramDeinit`, which frees the SRAM and leaves `sramBank` pointing into the
freed mapping -- so nothing re-pointed it, `GBMBCReset` having run before the
save was loaded, and `_GBMBC2Read` indexes `sramBank` directly because
`directSramAccess` is false for MBC2. First save read after boot, freed memory.

MBC7 (`0x100`) and TAMA5 (`0x20`) take the same early return. Their read
handlers go to mapper registers rather than `sramBank`, so they do not fault,
but their bank pointer was equally wrong.

`mgba-emu/mgba` master already carries this fix and `libretro/mgba` has not
rebased onto it -- the bug is in our pinned `e31759b2` (2026-08-05) and in
libretro HEAD `7a12d6d4` alike, so **bumping `MGBA_COMMIT` would not have fixed
it.** The patch follows upstream's shape so it fails to apply once libretro
picks the fix up, which is the signal to delete it.

The lesson for the port: "it is inside the core, past the seam" was true about
the location and wrong about it being out of reach. Core patches now have a
home at `cores/mgba/patches/`, applied after upstream slot's and hashed into
the build stamp.

### MBC2 saves do persist, despite the missing log line

The load logs no `emu: save ram` line where an MBC1 cart does (Alleyway DX:
`save ram, 8192 bytes`), and that was written up here as "MBC2 saves probably
do not persist". **Wrong** -- checked on the card afterwards:

```
-rwxrwxrwx 1 root root  256 Oct 14 21:02 Saves/GBC/Kirby's Pinball Land DX.sav
```

256 bytes, which is exactly MBC2's `sramSize` of 0x100, and the contents are
real rather than blank -- `ff` fill for the first 27 bytes and then score data.
So the save path works; only the *log line* is missing, because mGBA's libretro
layer defers `core->reset()` to the first `retro_run` (`_doDeferredSetup`,
"need to defer resetting the core on start so drivers are initialized") and
`retro_get_memory_size(RETRO_MEMORY_SAVE_RAM)` therefore returns 0 when slot
asks at load time. slot writes the save from the core's own buffer regardless.

The lesson is the one this file keeps re-learning: a missing log line is
evidence about the logging, not about the thing it would have described. The
save file was one `ls` away the whole time.

## The backlight is a PWM channel, and its response is steeply non-linear

There is **no `/sys/class/backlight`** on this device and no Allwinner dispdbg,
which are the only two things upstream's `set_backlight` knows. It therefore
found no backlight, wrote nothing, and failed silently at two jobs that did not
look related: closing the lid left the screen lit, because `Power::on_close`
writes step 0 and step 0 went nowhere, and slot's brightness HUD moved its own
number while the panel ignored it.

The panel is driven straight off a PWM channel:

```
/sys/class/pwm/pwmchip0/pwm0/{period,duty_cycle,enable,polarity}
period=800  duty_cycle=6  enable=1  polarity=normal
```

`.tmp_update/updater` sets `period=800`, `duty_cycle=6`, `enable=1` at boot.
Allium writes the same channel by its device-tree path,
`/sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/duty_cycle`.

**Measured by stepping a ladder on the device and looking at it** (2026-10-14),
against the 800 ns period:

| duty | what it looks like |
|---|---|
| 0 | off |
| 1 | not visible at all |
| 2 | dimmest step that is visible |
| 6 | the firmware's own boot value, comfortable |
| 112 | as bright as anyone wanted |
| 400 | "extra bright", well past useful |

So the response is concentrated in the bottom few percent of the period, and
**scaling the period the way the class backlight scales `max_brightness` is
wrong** -- it would put step 1 of 9 at 89, brighter than the device's own
default, and step 9 at 800. `patches/0008` carries a measured table instead:

```
step  0  1  2  3  4  5   6   7   8   9
duty  0  2  3  5  9  15  25  41  68  112
```

Confirmed on the handheld: the lid now darkens the screen and restores it, the
brightness HUD moves the panel, and the probe line reads `backlight pwm (0 to
112)` where it used to read `no backlight`.

### Closing the lid dozes; it deliberately does not suspend

**Decided 2026-10-14, not an open question.** A closed lid runs slot's own
`doze`, and that is the intended behaviour here:

- the hall poll (150 ms) raises `Btn::Lid` -> `Action::LidClose` -> `doze()`;
- `doze` flushes the state writer and the resume snapshot, so **shutting the
  lid is a save point**;
- the cart moves from `Phase::Playing` into `Phase::Doze { cart }`, which parks
  it for the wake;
- `sync_speed` includes `dozing()`, so the core goes to `Speed::Paused` -- the
  game is not running behind a dark screen, and the audio ring goes quiet;
- `power.on_close()` writes backlight step 0, which is duty 0;
- after `DOZE_TIMEOUT`, 180 s, `on_doze_timeout` powers the handheld off.

The SoC stays awake for those three minutes and the radio stays associated,
which is why FTP keeps answering with the lid shut. Allium suspends instead
(`power.json` has `lid_close_action: Suspend`; alliumd logs `suspending...` and
`waking up from suspend...`), so a vendor path exists -- but doze is what this
port uses. It is upstream's behaviour, it saves on the way down, and it wakes
instantly. Do not reach for `/sys/power/state` here without a measured reason:
the drain over a three-minute window has never been measured, and a suspend
path on this SoC would be new guesswork against the rule that killing or
bypassing the vendor stack is what made the handheld power off before.

## The lid: poll `hallvalue`, there are no events

**Resolved.** The clamshell sensor is a platform device and exposes its state at

```
/sys/devices/soc0/soc/soc:hall-mh248/hallvalue     1 open, 0 closed
```

which is the same convention slot's `read_lid` already expects — it was only
looking under `/sys/class/power_supply`, which this device does not have at all.
`patches/0003` points it at the right file and keeps upstream's search as the
fallback.

Sampling it once a second across a lid cycle, written to the card so the record
survives the device suspending, gave: `1` throughout, then a single `0`, then
nothing — **the system suspends about a second after the lid shuts**. So there
is one poll's worth of warning and no more, and nothing at all to count edges
from, which settles the question below.

### Why not events

The sensor emits no evdev events for a lid cycle. Five or six cycles produced
nothing on `event1`; the single `KEY_POWER` pulse in the trace came at 8 s
uptime, i.e. boot. The pops heard on each transition are the amplifier powering,
not something slot can see.

### The old note, kept because it was wrong in an instructive way



The one pulse that *was* captured looked like the whole story, and it is not —
it is the boot-time one. It emits a momentary `KEY_POWER` press and release in
the same millisecond:

```
35994ms event1 type=0x01 code=0x74(116) value=1 -> Power
35994ms event1 type=0x01 code=0x74(116) value=0 -> Power
```

Concluding from it that the lid had to be driven by edges would have been
wrong, and would have rebuilt the same guesswork that made closing the lid shut
the handheld down in the first place. More cycles showed there were no further
events at all, and the state file turned up by searching sysfs for the chip name
from the probe.

## Picture geometry: the canvas is the panel, the picture is not

`OUT_W` x `OUT_H` is the canvas, 752x560, which `patches/0002` set to this
panel. `GAME_W` x `GAME_H` is the *picture*, 720x480, and it stayed at
upstream's size on purpose -- `SRC_W` and `SRC_H` derive from it
(`GAME_W / SCALE`), so raising it would resize the 240x160 source texture. The
two being different is what this device introduced; upstream's are equal, which
is why its "stretch" filled the screen by construction and ours did not.

Measured sizes on this panel, for a 160x144 Game Boy picture (2026-10-15):

| mode | picture | paper each side | pixels |
|---|---|---|---|
| actual (R1) | 480x432 | 136px | uniform 3x3, pixel-exact |
| stretch (L1) | **622x560** | 65px | 3.889x, fills the height |
| *rejected* | 752x560 | 0 | 21% wider than square |
| *rejected* | 640x560 | 56px | uniform 4x4, **crops 2 source rows top and bottom** |

**4x was built, looked at, and disliked for the crop** -- which the arithmetic
had preferred: at 640x560 it is 2.9% *bigger* than the aspect-correct 622x560
and perfectly uniform, where 3.889x lands 16 of 144 rows 3 pixels tall against
128 at 4 (a thin row every ninth, and the same every ninth column). Only the
panel could decide that; do not re-derive it from the numbers.

GBA is pixel-exact 3x in both modes. `source_rect` returns the whole texture
for it either way, so stretch is already a no-op upstream, and the largest
aspect-correct fit here is 3.133x -- non-integer pixels for 4% more picture.

Sizes are multiples of the **whole 240x160 texture**, not of the picture inside
it. That is what keeps it cheap: the paper scales with the picture, `pic` keeps
gating the lcd3x grid at the same texel boundaries, and the canvas clips the
overhang -- paper first, picture only once the panel runs out.

### The source rect and the destination multiply

The renderer spreads `source_rect`'s texels across `screen_rect`'s rectangle,
so the two are a product. Upstream cropped the source to the platform picture
when stretching and drew that crop across a canvas-sized destination. Sizing
the destination from the texture *as well* multiplies them: a stretched Game
Boy shipped for one build at **5.83x by 4.32x**, a 933x622 picture on a 752x560
panel, wildly zoomed and cropped.

Each half was correct alone, which is exactly why a test of each half passed.
`the_effective_scale_is_never_doubled_up` checks the product instead -- that it
is square and fits the panel -- and was confirmed to fail on the broken version
before being trusted. **When two numbers are multiplied downstream, test the
product.**

## The console's bezel sits at the picture's frame, not at the canvas

Upstream's per-platform bezels (`assets/bezel_gb.png`, `bezel_gbc.png`, baked
into `slot-ui`) are 720x480 with a transparent hole **478x429 at (121, 27)**,
measured off both files. That hole is the 160x144 picture at 3x, where it sits
inside the 240x160 texture: 480x432 at (120, 24), to within the art's own dark
inner edge.

Upstream makes the art canvas-sized, because its canvas *is* 720x480. Here the
canvas is the 752x560 panel, so `art::cover`-ing the bezel to it put the hole
39px out on every side. The port builds the faces at `PICTURE` -- the frame,
720x480 -- and draws them there, which lines the hole up with the picture by
construction: both are centred in the same canvas.

It is drawn with the surround rather than over the game. The band the bezel
covers is paper, and paper does not change between frames; only the picture
does. So the game pass is cropped to the picture (`Game::crop`) and the bezel
is composited into the panel-sized surround that `output_frame` paints when
the output rect moves. In play it costs nothing per frame, where upstream's
full-frame draw would be 345,600 pixels of blit on every one of them. The
canvas path -- a menu is up, the canvas covers the panel, the surround is not
in view -- still draws it per frame, as upstream does.

`the_picture_fills_the_hole_in_the_art` pins the hole's numbers above against
the crop's arithmetic. Nothing lines the two up at run time.

Seen under qemu on 2026-10-15 for GB (mGBA's DMG boot logo in the hole, the SP
lettering correctly absent) and for GBA (SP shell unchanged). Not yet on the
handheld.

## Memory: slot is 44 MB before a core, 78 of ~80 with one (2026-10-16)

A GBA cart kept being OOM-killed mid-game -- `exit=137`, signal 9, no core
dumped. Measured with `/proc/<pid>/smaps` aggregated by mapping, which is the
measurement that should have been taken first:

| | RSS | `[anon]` | `[heap]` |
|---|---|---|---|
| shelf, no core loaded | 44 MB | 27 MB | 16.9 MB |
| playing, gpSP loaded | **78.5 MB** | 61.4 MB | 16.9 MB |

`MemAvailable` with slot up and a game running: **1.9 MB**. The device has
101 MB and the system holds about 20, so the ceiling is near 80 and slot sits
on it. Everything grows into that margin: the JIT cache as code is translated,
the rewind ring as it fills, the gamepak buffers as the ROM is paged.

Where it goes, from slot's own texture inventory (`SLOT_TRACE_LATENCY=1` logs
every texture as it is created):

| | |
|---|---|
| 18 cart faces, 312x337 | 7.2 MB |
| 2 full-screen grounds, 752x560 | 3.4 MB |
| 9 GBA-sized cart art, 360x212 | 2.6 MB |
| 62 cart title faces, 242x24 | 1.4 MB |
| 6 footer strips, 752x58 | 1.0 MB |
| everything else | ~6 MB |
| **slot's textures** | **22.1 MB over 300 textures** |

gpSP's share is about 34 MB: 8 MB of ROM, a 10.5 MB JIT cache mmapped at core
start (`map_jit_block(ROM_TRANSLATION_CACHE_SIZE + RAM_TRANSLATION_CACHE_SIZE)`),
and gamepak buffers that `init_gamepak_buffer` mallocs 1 MB at a time "up to
32 blocks" whatever the ROM's size -- capped to 16 in `cores/gpsp/build-miyoo.sh`.

**There was no way to free a texture.** A shed one went onto `CartFaces`'s
free list and was recycled by `update_texture`; nothing was returned to the
system. Three separate savings were made before anyone noticed, and none of
them moved RSS: they reduced how many textures were *created*. `free_texture`
(`patches/0018`) is the fix, and it is what made a GBA cart playable.

### What each thing was actually worth

| | claimed | real |
|---|---|---|
| rewind scaled by state size (0017) | 13.5 MB + 9 MB/s of CPU | a cart that died in a minute lasted fourteen |
| cart faces, drawn span only (0016) | 3.8 MB | fixed a 1.5 s lockup; freed nothing until 0018 |
| grounds, wallpaper, faces freed in play (0018) | 8 MB | the one that made it playable |
| gpSP cache cut to 2 MB | 8 MB | **reverted** -- Kirby thrashes on a 2 MB cache |

The last line is the lesson: the JIT cache is what makes gpSP fast, and taking
it is paying for memory with the thing the memory was for. Take the art
instead, which is not on screen while a game is.

### Rewind is a 1 GB device's feature

`Rewind::push` copies the state, XORs it against the previous one and LZ4s the
result, every `SNAPSHOT_EVERY` frames, into a `REWIND_BYTES` ring. Upstream's
2 frames and 20 MB are fine for a 24 KB Game Boy state and ruinous for a
425,984 byte GBA one: thirty pushes a second is ~12 MB/s of memory traffic
beside the emulator, and the ring fills 20 MB of this device inside a minute.
`rewind::plan` scales both with the state -- every 9 frames and 6.5 MB for
GBA, upstream's numbers below about 150 KB.

## Working on the patch series without breaking it

**Replay the series as commits, not as files.** `git apply` was how this port
rebased for a year, and it does not survive a real upstream move: the 2026-10-15
bump was 94 commits and rewrote the canvas and layout the renderer patches sit
on. What worked, and is the recipe for the next one:

```sh
task unpatch
cd upstream/slot && git fetch origin main
git checkout -B port <pinned-sha>
# one commit per patch, in patch order
for p in ../../patches/*.patch; do
  git apply "$p" && git add -A && git commit -q -F <message>
done
git rebase origin/main          # git's merge machinery, not git apply's
```

Conflicts then arrive one patch at a time with a base to merge against, and
the result is testable at the tip before a single patch file is rewritten.
Regenerate them from the branch afterwards: the message is the commit message,
the body is `git format-patch -1 --stdout --no-signature`, and the two are
joined with a blank line.

Three things to keep right when you do:

**Order the branch by dependency, then renumber nothing.** A patch's hunks are
cut against the tree its predecessors leave, so 0010's test helper has to exist
before 0010 uses it (it comes from 0008), and 0009 needs 0002's canvas. The
first rebase came out in a different order and renumbering would have stranded
every `patches/00NN` reference in these notes; cherry-picking the finished
commits back into the original order cost one conflict and kept them all.

**Run `cargo fmt` as part of each commit, not once at the end.** Formatting the
tip reformats code that belongs to earlier patches, which lands their changes in
the wrong patch file -- and rustfmt 1.96 does reformat several of these files.
Cherry-pick, `cargo fmt --all`, `--amend`, next.

**Keep the generated message clean.** Several patch files begin with prose and
then a bare `--- a/path` with no `diff --git` line; taking "everything before
the first `diff --git`" as the commit message swallows the whole diff into it,
and the regenerated file is then a patch git calls corrupt at the line where
the duplicate begins. Cut the message at the first `--- a/` too.

**One patch no longer has to own a file.** `task patch` used to decide a patch
was already applied by reverse-checking it, which a later patch editing the
same lines makes false; 0013 edits a file 0002 creates, and 0002 then read as
stale on a tree it had just patched. It now stamps `upstream/slot/.port-patches`
with a hash of the patch set instead, so the question is whether *this* set is
what is on the tree. A mismatch on a modified tree asks for `task unpatch`
rather than re-applying over it.

## Panel orientation

**The LCD is fitted upside down.** A frame written top-down to `/dev/fb0`
appears inverted on the panel — confirmed on the device, and the reason
`card/System/launch_frontend.sh` exports `SLOT_FB_ROTATE=180`. `fb0/rotate`
reads `0`, so nothing in sysfs advertises this.

## Buttons — keyboard codes, not gamepad codes

This is why the first on-device run ignored every press: slot's `code_to_btn`
maps `BTN_*` gamepad codes (`0x130`+) as the Anbernic handhelds report, but
`soc:gpio_keys` here reports **keyboard** codes, so every lookup missed and
`pick_devices` rejected the node outright.

Decoded from the `B: KEY=` bitmap the probe captured, and cross-checked against
Allium's own Miyoo map — the two agree exactly on all 18:

| code | key | slot button |
|---|---|---|
| 103 / 108 / 105 / 106 | UP / DOWN / LEFT / RIGHT | d-pad |
| 57 | KEY_SPACE | A |
| 29 | KEY_LEFTCTRL | B |
| 42 | KEY_LEFTSHIFT | X |
| 56 | KEY_LEFTALT | Y |
| 18 / 20 | KEY_E / KEY_T | L1 / R1 |
| 15 / 14 | KEY_TAB / KEY_BACKSPACE | L2 / R2 |
| 28 | KEY_ENTER | Start |
| 97 | KEY_RIGHTCTRL | Select |
| 1 | KEY_ESC | Menu |
| 115 / 114 / 116 | VOLUMEUP / VOLUMEDOWN / POWER | as named |

The d-pad arrives as keys, not as `ABS_HAT0X/Y`, so upstream's `Hat` decoding
never fires here either.

### And `struct input_event` is 16 bytes here, not 24

This was the actual reason buttons did nothing, and slot's own input trace
found it. The struct opens with a `timeval`, two C longs wide, so it is 24
bytes on a 64-bit kernel and **16 on this 32-bit one**. Reading 24-byte records
out of a 16-byte stream slides every field by eight bytes, so the timestamp is
read as type/code/value. The trace is unmistakable once you know:

```
2113ms event0 type=0xba29 code=0x3a36(14902) value=565800 -> ignored
2553ms event0 type=0xba2a code=0x3a36(14902) value=5791   -> ignored
3603ms event0 type=0xba2b code=0x3a36(14902) value=55766  -> ignored
```

`type` should be 0..0x1f. That slowly incrementing `0xba29, 0xba2a, 0xba2b` is
the seconds field of the timestamp, and `value` is microseconds. Every event
decoded as noise and was dropped, which is why *nothing* responded rather than
the wrong things responding.

Fixed in `patches/0003`: the width is derived from `size_of::<c_long>()`.

### And the capability bitmaps are 32-bit here

`slot_power::has_bit` read these masks as 64-bit words. The kernel prints them
as `unsigned long`, which is **32 bits** on this device, so every bit above 31
was looked up in the wrong word — losing most of the keyboard range, including
`KEY_SPACE` (the A button). `pick_devices` only kept working by accident:
`KEY_ESC` is bit 1, low enough to land in the right word either way.

Fixed in `patches/0004`, with tests that pin the device's real bitmap and the
32-bit word maths explicitly, since `usize::BITS` on a 64-bit build host would
otherwise hide the whole case.

## Input

Two evdev nodes, which slot discovers by walking `/sys/class/input` already:

| node | name | notes |
|---|---|---|
| `event0` | `soc:gpio_keys` | all buttons, `EV=100003` |
| `event1` | `hall wake key` | **the clamshell hall sensor** |

Both are opened successfully — the trace confirms `event0 opened` and
`event1 opened` — so nothing is holding the devices grabbed and the node
selection works.

The lid sensor is a gift: slot already handles `SW_LID` in
`crates/slot/src/input/evdev.rs`, so closing the Flip can suspend as upstream
intends. Per-button codes still need an `evtest`-style capture — the probe lists
the devices but not the individual keycodes.

## What the device says about itself at boot

```
slot: panel 752x560, canvas 752x560, turned false, ccw false
slot: backlight no backlight (0 to 255), battery no battery, rtc0, no motor
slot: boot: first frame at 511.6 ms
```

So: no backlight control found, no battery (below), no rumble motor, but `rtc0`
is present. First frame in ~0.5 s on real hardware.

## `CONFIG_HZ` is 100: a 10 ms tick, and three bugs came out of it

```
/proc/timer_list -> CONFIG_HZ: 100     kernel 4.9.84
```

**Read this before writing anything that sleeps.** A frontend paced by short
sleeps is built on an assumption this kernel does not honour: `thread::sleep`
cannot land finer than a 10 ms tick, so any sleep of a few milliseconds may
return several milliseconds late. Three separate problems, each chased for a
while on other theories, were all this:

1. **The pacer's margin.** `Pacer::wait` sleeps `period - work - MARGIN` so the
   work finishes `MARGIN` = 1.5 ms before the blank and input is sampled late.
   A 5.9 ms sleep returning at 10 spends that margin four times over and the
   blank is gone. Measured: 9.4 ms of work against a 16.78 ms period, and 62%
   of frames taking two periods. Fixed by not pre-sleeping at all when the swap
   blocks, since the panel is then the clock -- 594 of 600 frames in one period
   afterwards.

2. **The core's own clock.** Unchained from the display (`SLOT_DRIVE_EMU=0`) the
   emu thread does `deadline += PRESENT`, then sleeps the remainder. After
   mGBA's 8.26 ms of work that is an 8.4 ms sleep, which overshoots -- and
   `deadline = now` on the late branch *discarded* the overshoot, making it
   permanent. The core settled near 52 Hz: a Game Boy that feels slow, and an
   audio ring starving in proportion (747,876 starved, `queued` down to 357 of
   4800). Fixed by carrying the debt forward and resyncing only past four
   frames of it. Ring now sits at 4159-5111 against its 4800 target.

3. **The "spikes" that were never spikes.** `read>pad` and `pad>emu` reaching
   30-50 ms read as a slow `advance`; they are queueing delays, and what was
   queueing was work waiting behind a loop that had lost its clock.

The general lesson, which cost most of a session: on this device, time a sleep
before trusting it, and prefer a hardware wait (the pan's vblank block) over a
timer whenever one is available.

## Frame budget, measured on the device

`SLOT_TRACE_LATENCY=1` in the card's launch script writes a per-frame breakdown
to `slot.log`. From the first run with a game going:

```
read>pad 18.3  pad>emu 0.3  emu>pub 10.1  pub>take 1.5  take>swapped 55.0  (swap 16.2)  total 85.4 ms
read>pad 23.6  pad>emu 0.3  emu>pub 14.1  pub>take 1.6  take>swapped 50.9  (swap  7.0)  total 90.5 ms
read>pad 39.0  pad>emu 6.8  emu>pub  9.6  pub>take 1.5  take>swapped 49.1  (swap  6.8)  total 106.0 ms
```

`take>swapped` is this backend — the rasteriser plus the output blit — and at
**~50 ms against a 16.7 ms budget** it was the whole problem. The emulator core
(`emu>pub`) runs in 10-20 ms and the panel swap in 3-16 ms, so neither is
anywhere near the limit. Optimise the renderer, not the cores.

Progress, p50 of `take>swapped`:

| | ms |
|---|---|
| first measured run | 52.9 |
| + rotated output memcpy | 36.2 |
| + 3x lookup for the game pass | 43.3 — **worse, and the path never ran** |
| + per-stage profiling | the game pass is 32 of the 47 ms |
| + flat column table, no per-pixel checks | 34.5 (game 32.6 -> 21.0) |
| + source row expanded once per source row | 26.5 (game 17.1, upload 0.4) |
| + NEON kernel for the row scale | 25.6 (**game 17.1 -> 7.8**) |
| + cached column table and scratch | — |
| + memset clear, all games on gpSP | 25.7 (stages sum to **12.8**) |
| + deferred clear | clear 0.9 -> **0.0**, stages 11.6 |
| + game straight to the framebuffer | **8.2** (clear 0.0, upload 0.2, out 8.0 incl. game) |

Worst single frame in each 60-frame window: p50 **15.4 ms**, p90 18.7, against a
16.86 ms period — where it had been 19-21 ms. `take>swapped` p50 11.1,
`emu>pub` 6.3.

### The swap is a page copy, not a latch (2026-10-13)

In game, averaged over the in-game window of a 442 s run:

```
read>pad 14.0  pad>emu 0.4  emu>pub 5.4  pub>take 1.3  take>swapped 14.6  (swap 6.6)
```

`swap` is `FBIOPAN_DISPLAY` with `FB_ACTIVATE_NOW`.

**This was first read as a whole-page copy -- 1.68 MB at the bandwidth the rest
of the backend sees is about 6.6 ms, which fits suspiciously well. It is not.**
It is a vblank wait, so those 6.6 ms are idle CPU, not spent work. The evidence
is `Pacer`: it learns its period only from frames where the swap blocked, and
it converged on **16.77 ms**, which is the panel at 60 Hz. A driver that copied
the page would have let the loop land anywhere; one that waits for the blank
pins it to the panel's period, which is what happened.

So the panel is 60 Hz and the median frame always fitted. What does not fit is
the spikes -- 30-50 ms, and `read>pad` / `pad>emu` / `pub>take` say they are
input and `advance`, not the renderer. Averaging over a window that includes
them is what made the frame look uniformly over budget.

That cost was invisible for a long time because `Pacer` measures `work` from the
top of the loop to the swap and not through it, so "work 15.5 ms, zero frames
missed" was really a 22 ms loop with `missed` only counting over 25 ms.

Consequences, all of them slot behaving correctly:

- the loop runs at ~20 ms, so `pacer.period` is what reaches the emulator as
  `present_ns`, the core is paced to it and the resampler scaled by the same
  factor — `SLOT_TRACE` showed it walking to **1.37**. Slow gameplay and a
  dropped audio pitch are the same fact.
- one underrun puts `Ring` into priming, where `fill` returns silence until the
  ring is half full again, so each late frame buys a run of silence. 444,368
  starved samples over that run, and a click every few seconds.

`SLOT_FB_PAGES=1` (launch script) caps the pages the backend will flip between.
With one page it draws at the scanout and waits for the blank instead, trading
the copy for a tearing risk.

Measured with it on, same game:

| | before | after |
|---|---|---|
| `swap` | 6.6 ms | **0.0 ms** |
| starved samples, per run | 444,368 | **26,830** |
| resample factor (`SLOT_TRACE`) | 1.37 | 0.94-0.96 |
| frames missing a latch, per 600 in game | ~200 | **5-9** |

**Reverted: it tears**, on the shelf and in game both. With one page the
renderer writes into the buffer being scanned out, and `swap` reading 0.0 ms
says this driver ignores `FBIO_WAITFORVSYNC` too, so there is nothing left to
synchronise against. The page flip is the only way to get a coherent frame
here, and its vblank wait is the price.

What the single-page run did prove is that the 6.6 ms was never the frontend's
to spend: giving it back did not make the frame cheaper, it only removed the
synchronisation.

### So the core is unchained from the display instead (`SLOT_DRIVE_EMU=0`)

Driven mode makes the emulator wait for a present tick, so the display's rate
becomes the machine's rate: a display dragged to 50 Hz by spikes is a 50 Hz
Game Boy, slow motion with the audio stretched to match. That stretch is not
drift -- `rate.served` measures the real tick interval and the resampler
follows it honestly, which is where 1.37 came from.

Unchained, the core keeps its own 59.73 Hz and the display drops what it cannot
fit. Measured: `locked false at 0.00000`, so the resampler sits at 1.0 and the
pitch is right; frames missing a latch fell from ~200 per 600 to **21-38**; and
the tearing is gone.

The cost moved to the ring. Nothing stretches the audio over a spike any more,
so a 30-50 ms spike simply drains it: `queued` was measured at **540 frames
against a 3200 target**, 11 ms from empty. Hence `RING_FRAMES` 12 rather than
upstream's 8 -- 200 ms of ring, half of it the target -- which gives the
self-paced core room to catch up. `SLOT_RING_FRAMES` tunes it.

What is left: the shelf costs **28.8 ms a frame** in sprites over 194 draws now
that it fills the panel, so the menu runs at about 35 Hz. Nothing depends on
the menu's frame rate the way audio depends on the game's, but it is the
largest number left in the backend.

### The shelf's cost was alpha, not geometry (2026-10-15)

Scrolling felt uneven. Measured over 19,200 frames with `SLOT_TRACE_LATENCY=1`,
the shelf's `work` sat at **18.0-19.3 ms against a 16.77 ms period** -- just
over, which is the worst place to be: the `<27` interval bucket is always
**zero**, so every frame takes either one panel period or two, and 250-450 of
every 600 take two. 60 Hz alternating with 30 reads as jerky at a mean of 45.

Where it went, and three wrong answers on the way:

| | |
|---|---|
| 186 rects | **0.3 ms** -- they write 0.14 of a screen between them |
| 8 textured draws | **30-36 ms** -- all of it |
| the fix | **15.3-18.2 ms** |

**Rects were the first wrong answer.** "186 rects at 59 us each" was an
inference from the stage total; counting their pixels showed 0.14 screens and
`fill_rect` already memcpies a prepared row. Timing each draw *kind* separately
is what found the eight textured draws.

**The texels were the second.** Two draws of identical geometry measured 2.5
and 16.0 ms, one copying 98,810 pixels and the other blending 99,520, with
*identical* counts of fully transparent pixels. That looks exactly like a face
whose alpha is a hair under 255, so `clip_to_silhouette` and both shell
silhouettes were checked on the host, then `cart_face` with the real cover art,
then all twelve 312x337 textures under qemu with the whole GBC shelf planted
into a root. All opaque. A texture-alpha dump at upload on the device then said
the same: **98,651/98,818 opaque**, matching the host exactly.

**The answer was the draw's own alpha.** The shelf fades each cart face while
scrolling -- 0.140, 0.159, 0.236 mid-animation -- and `blit`'s fast path wanted
`colour == [1.0, 1.0, 1.0, 1.0]` *exactly*. Anything less fell to `modulate`
per pixel: four float multiply-clamp-casts over ~90,000 pixels, three faces a
frame. Worse, the lift eases *towards* 1.0 and lands at **0.9996**, so a cart
sitting still at apparent full opacity blended all 99,520 of its pixels, 10.0 ms
in one draw.

Two changes, both in the blit, both bounded by tests against the reference:

- `alpha_table`: slot only ever tints with white (`Draw::Tex` passes
  `[1,1,1,alpha]`), so three of `modulate`'s four multiplies are by 1.0. One
  256-byte table per draw and a byte lookup per pixel instead -- bit-identical,
  since `v as f32 * 1.0` is `v`. 30-36 ms -> 21.
- `plain_enough` and `OPAQUE_ENOUGH`: a tint or a texel within **one level** of
  opaque is treated as opaque. Invisible, and it took that 10.0 ms draw to
  2.47. 21 ms -> 15.3-18.2.

What remains is honest: a cart genuinely at alpha 0.55 costs 3.8 ms to blend
and must. The next lever is the overdraw visible in the same trace -- each cart
draws an opaque silhouette (`id 23`, 1.2-2.7 ms) *underneath* its face, which
is wasted wherever the face above it is opaque, about 5 ms a frame.

**My own instruments lied twice here**, which cost two device rounds. The
per-draw log printed `(alpha * 255).round()`, so 0.998 printed as `255` while
failing the exact test; widened to three decimals, 0.9996 printed as `1.000`.
An instrument that rounds away the exact quantity under test is worse than
none. It is logged in thousandths now, and the rule generalises: **print the
value the code branches on, not a rendering of it.**

### What is still unexplained

The pacer reports `work 36-45 ms` while `take>swapped` is 11 and the core is 6.
`work` is measured from the top of the loop to the swap, so it also spans
`advance` and `step_emulator`, and the latter can block waiting on the emulator
thread. That would make most of it *waiting* rather than work, which is what the
healthy frames suggest — `total 17.8 ms` on a good one — but it has not been
proven, and it is the obvious thing to measure next if the stutter persists.

With everything on gpSP: `emu>pub` 6.4, and the backend's own stages are
clear 0.9, upload 0.3, game 8.6, sprites 0.0, out 3.0 — **12.8 ms**, inside the
16.77 ms period. The memset took the clear from 1.4 to 0.9.

### The gap is not the renderer

`take>swapped` is 25.7 against stages summing to 12.8, and the pacer reports
`work 28 ms`. That ~13 ms is now larger than anything left in the rasteriser,
and it is *not* in the rasteriser: `latency::taken()` fires immediately after
`upload_game`, and the whole of `Frontend::compose` runs after it —
`cart_faces.sync`, `sync_clock`, `sync_about`, `sync_quick_clock`,
`sync_core_picker`, texture uploads, then building the display list. All of it
lands inside `take>swapped` and none of it inside the backend's profile.

`patches/0005` times that block temporarily, printing `slot: compose: sync N
build N ms/frame`. It is diagnostic only and should be dropped once the budget
is settled.

**It was not the sync work.** Measured, that block is **0.1 ms a frame** — the
guess was wrong. The gap is the swap:

```
swap  p50=11.4  p90=15.3  max=15.9 ms
```

`take>swapped` 25.2 = about 12.5 ms of render plus 11.4 ms of *waiting*.
`FBIOPAN_DISPLAY` was being issued with `FB_ACTIVATE_VBL`, which blocks until
the panel latches — capped at one 16.7 ms period, which is exactly the shape of
that distribution. slot paces itself, so blocking here too put two pacers in
series and spent most of the budget on nothing.

It now pans with `FB_ACTIVATE_NOW` and returns; the hardware still latches whole
pages at its own blank and there are three of them, so tearing is not expected.
`SLOT_FB_VSYNC=1` restores the blocking behaviour if that turns out to be
wrong.

With gpSP the stages add up to about 12.4 ms (clear 1.4, upload 0.3, game 7.8,
sprites 0.0, out 2.9) and slot's own pacer agrees: `work 12.7 ms, period
16.76 ms`, the first time work has fit inside the period. It reads as mostly
smooth with occasional stutters, which is a variance problem rather than a
throughput one — hence caching the column table (2160 `sin()` calls a frame)
and the two scratch buffers that were being heap-allocated every frame.

`take>swapped` still reads ~25 ms against stages that sum to 12.4, and that is
not reconciled. The pacer's `work` number suggests the difference is waiting
rather than work, but it has not been proven either way.

The frame upload was the ~10 ms that the stage timings could not account for:
it converted 38,400 pixels one three-byte copy at a time, before any of the
timed work. It is one memcpy now, 0.4 ms.

### gpSP is worth more than any of this

| GBA core | `emu>pub` |
|---|---|
| mGBA (interpreter) | 14.2 ms |
| **gpSP (ARM JIT)** | **5.5 ms** |

Pick it with START on the shelf over a GBA cart. This is the single largest win
in the whole exercise and it is a menu option.

Per-stage, from the device:

```
slot: soft: clear 1.2 game 32.6 sprites 0.0 out 2.7 ms/frame, game path separable
```

So the clear, the sprites and the output are all cheap, and the game pass is
the whole remaining cost. `game path separable` also says the 3x lookup does
not run: GB and GBC are 160x144 inside the 240x160 buffer, so the source and
picture rects are partial and the scale is 4.5x across, not 3x. The lookup only
ever fits GBA.

### What is left in the game pass: probably nothing cheap

Per frame in play the backend writes the 1.38 MB of the framebuffer itself,
which is the frame and cannot go away, plus about 829 KB into the `line`
intermediate — one expanded row per *source* row, 144 of them for GB.

That intermediate is worth keeping, not fusing away. It exists so each source
row's gather happens once and is reused across the three-odd output rows that
map to it, and so the NEON kernel reads linearly. Removing it would multiply the
scattered reads by that factor and break the vectorised path.

The canvas round trip is already gone: the game pass writes straight into the
framebuffer when the display list is only the game, which the profile shows as
`game N (inside out)`. Anyone looking at this again should profile *inside* the
game pass, splitting expansion from scale, before changing anything.

### `task shot` is not deterministic, so it cannot prove pixel-identity

Two runs of **identical code** differ: 873 pixels across 69 rows, in the same
small band on each page (rows ~246-266 of each). Something in the captured
frame varies with timing. So "verify renderer changes pixel-identical with
`task shot`" only holds for changes larger than that noise floor -- the sprite
blit rewrite moved 639 pixels, fewer than the noise, and the screenshot could
not tell the two apart.

Use a reference implementation in a unit test instead, as
`raster::blit_tests` does: the old straightforward loop kept beside the
optimised one and compared over every scale, both colour paths, fractional
offsets and clipping. That is deterministic and it is what `blend_tests`
already did for the divide. `task shot` remains the right tool for *seeing*
what is drawn, which is what it was built for.

### The sprite path

Measured at a fixed draw count, which is the only way these numbers mean
anything:

| | sprites at 186 draws |
|---|---|
| before | 12.0 ms |
| after the divide and bounds checks came out | **9.7 ms** |

About 19%, or 0.052 ms a draw. It does not touch gameplay — `sprites 0.0 over
0 draws` there — and was never going to: the shelf and menus are what it is
for. A 20.6 ms reading taken in between was a busier screen, not a regression,
which is why the draw count is logged alongside now.

### NEON will not come for free here

The horizontal scale makes the source read a **gather** — each output column
takes an arbitrary source texel — and NEON has no gather instruction. Cleaning
the loop up (no bounds checks, no per-pixel branch) did not make LLVM
autovectorise it, and would not have: the obstacle is the access pattern, not
the loop shape. Vectorising this needs the row expanded to destination width
first, or a `vtbl` shuffle exploiting the fixed scale ratio, and either way it
needs inline asm or a C shim, since the intrinsics are unstable here.

**Done, as inline asm.** Two things to know if you touch it: the assembler
needs `.fpu neon` inside the block, because the target feature cannot be named
on stable for armv7; and a 16-bit scalar operand to `vmull` must live in
`d0`-`d7`, so the row factor goes in `d4` rather than anywhere convenient.
`task test` runs the workspace as armv7 under qemu, which is how the kernel is
checked against its scalar reference — the only way to exercise it short of the
handheld.

The expansion is now done anyway, for its own sake: each *source* row is
expanded once to destination width with the column mask folded in, and reused
for the three-odd output rows that map to it, which cuts the gather work by
that factor. The remaining per-output-row loop is linear, so it is the right
shape for NEON — LLVM still will not take it (4-byte stride, three channels of
four, u16 to u32 to u8), but hand-written it is now a simple widening multiply
by a row scalar rather than anything clever.

The lesson from the middle row: the memcpy fast path was first written with
`!half` in its condition, and this panel is *always* rotated, so it never ran
once and the number did not move. Measure the change, do not assume it.

## Ejecting is not slow; deploying over it is (2026-10-13)

A GBA eject was felt as a 15 s stall. `flush_eject` runs on the UI thread by
design -- the shelf must not show the cart out of the slot before the data is
down -- and for a GBA cart that is 425,984 bytes of state plus 131,072 of save
RAM, each fsync'd and followed by a directory fsync on vfat. A plausible 15 s.

It is not. Measured on the device with a timing patch (0006, dropped
once it had answered -- `git log -- patches/0006-time-the-eject.patch` has it
if a recurrence ever needs it back):

```
slot: eject: join 0 ms, snapshot 19 ms, write 170 ms for 557056 bytes
slot: emu: stopping at 27885.9 ms -> stopped at 27926.2 ms          (40 ms)
slot: prefetch: 16777216 bytes of Kirby ... in 366.0 ms
```

Under 0.6 s end to end, and `join 0 ms` rules out colliding with an autosave
already in flight (autosaves write on their own thread; `settle_saves` joins
one before the eject writes again). The eject animation is `*t += dt` bounded
by `EJECT_S` = 0.35 s, so nothing in-process accounts for it either.

What was different: `task deploy` was running, which pushes ~10 MB over FTP to
the same vfat card the game is reading and writing, and which is also why a
deploy drops you back into Allium. **Do not judge device timings taken while a
deploy is in flight**, and prefer ejecting and relaunching before pushing.

Confirmed: every eject since, with nothing deploying, has been quick.

## The lid shuts the handheld down

`event1 "hall wake key"` advertises `KEY_POWER`, so closing the clamshell
decodes as a power-button press and slot acts on it. slot's own lid support
reads a `hallkey` file under `/sys/class/power_supply`, and **that directory
does not exist on this device at all**, so `find_hall` returns `None` and there
is nothing else feeding `Btn::Lid`.

For now the hall node's key events are dropped rather than acted on
(`patches/0003`), so the lid does nothing instead of shutting down. Wiring it up
properly needs the open/close signalling, which the input trace is back on to
capture: whether it holds a value across the closed state, or just pulses on
each transition, decides whether it can drive `Btn::Lid` directly.

## Allium's daemon fights slot for the MENU button

`alliumd` keeps running underneath whatever it launches, and it owns MENU
globally: it draws a "Global Hotkeys / Ingame Hotkeys" overlay over the running
game and claims MENU plus power, volume and brightness. slot wants the same
button — a tap is its quick menu, a hold ejects — so both react to every press.

This was the real cause of the menu button feeling broken, and it is invisible
from slot's own logs: the gesture log showed slot deciding correctly all along.
Capturing `/dev/fb0` over the network and looking at it is what settled it,
which is worth remembering as a diagnostic — `dd if=/dev/fb0` on the device,
then `tools/fb2png.py`.

**Do not kill `alliumd`** — and the reason turned out to be mundane. The card's
boot hook, `.tmp_update/updater`, ends like this:

```sh
RUST_LOG=info "$ROOT"/.allium/bin/alliumd >"$ROOT"/allium.log 2>&1
...
else
    while true; do
        reboot
        sleep 10
    done
fi
```

Killing `alliumd` makes that script continue past the launcher and hit the
reboot loop. The "hard shutdown when launching a game" was the handheld being
told to reboot, not a power fault or a watchdog.

The right way to have the machine to ourselves is to boot slot *instead of*
Allium, from that same hook. See "Booting straight into slot" in the README:
a `.slot-boot` file at the card root selects it, deleting the file undoes it
from any computer, and if slot exits the script falls through to Allium rather
than to the reboot loop.

## Why gesture timers misfire: `advance` drops input during a rebuild

Symptoms seen on the device: an 8.5 second hold of MENU producing no eject at
all, ejects and quick menus resolving about 250 ms *after* the release rather
than at the moment they are due, and the whole thing being intermittent.

`Frontend::advance` is the cause, or at least a sufficient one:

```rust
let events = input.poll(now);
if self.rebuild.is_some() {
    return;                         // events discarded here
}
self.session.feed(events, now);     // and feed is what calls gestures.tick
```

While a label or face rebuild is running, input is polled and **thrown away**,
and `Gestures::tick` never runs — so no hold timer advances and no press is
recorded. A hold that spans a rebuild cannot eject, and the press that follows
resolves against a stale clock.

**Status: mechanism found, not confirmed active.** slot does not log rebuilds,
so there is no evidence in the captured logs that one was running at the time.
Confirming it is one `eprintln` on that early return, behind
`SLOT_TRACE_LATENCY`.

Ruled out along the way: the chord path (no SELECT events appear in any trace)
and the double-tap path (the press in question came 671 ms after the previous
tap, outside the 350 ms window). Both of those also clear `menu_down_at`, so
they were worth eliminating.

If it is confirmed, the fix is a judgement call rather than an obvious one.
Upstream presumably intends input to be ignored while rebuilding; the harm here
is that events are *discarded* rather than left queued, and that the timers stop.
Rebuilds are also slower on this device than the hardware slot was written for.

## Button bounce

The polled GPIO emits spurious transitions. From the trace, three in a single
millisecond:

```
9289ms  release
9289ms  press
9289ms  release
```

That alone can manufacture a double tap, which lands on the polaroids screen.
Worth remembering before blaming gesture thresholds.

## Never overwrite the live binary

With slot as the boot process, `curl -T` straight onto `System/slot` hangs the
handheld: FTP truncates the file on open, and the running process loses the
pages it is executing from. Reachable one moment, gone the next, with no
network and no response to buttons.

`task deploy` uploads to `slot.new` and renames over the top, which is atomic
and leaves the running process on the old inode. The new build is picked up on
the next start.

Recovery, if it happens anyway: force the handheld off with the power button. A
truncated slot fails to start, and the boot hook falls through to Allium. If it
hangs instead of falling through, delete `.slot-boot` with the card in any
computer.

## Battery: a vendor tool, not sysfs

There is no `/sys/class/power_supply` at all. The charge is behind
`/customer/app/axp_test`, which prints one line:

```text
{"battery":93, "voltage":4026, "charging":0}
```

`patches/0004` reads it when sysfs has nothing, which is what gives slot its
indicator back. **Working as expected on the handheld**, confirmed 2026-10-15.

The probe line used to be misleading about it, printing `battery no battery`
because that field reported `self.battery`, the sysfs directory, which really is
absent -- while `battery()` checks the vendor tool first and succeeds. It was
read as an open gap once, days after the indicator started working.
`patches/0010` names the source instead, confirmed on the handheld:

```
slot: backlight pwm (0 to 112), battery axp_test, rtc0, no motor
``` Allium reads the same tool on this hardware. The other source is
the SAR ADC behind `/dev/sar` and two vendor ioctls — a lot of machinery for the
same number, and Allium only uses it on the older model.

## Crash handling

`slot.log` is rotated to `slot.log.1` each start, and slot's own signal handler
prints the faulting pc and lr (the armv7 register read is `patches/0001`). On
top of that the launch script now:

- installs `coresave-miyoo.sh` as `core_pattern`, which wraps upstream's
  `coresave.sh` with this card's path — the kernel runs a pipe program with none
  of our environment, and upstream defaults to the Anbernic `/mnt/sdcard`
- raises the core limit and makes `$SD/crash/`
- records every exit in `crash/exits.log` with its status, and copies the log
  aside when the status is above 128, meaning a signal killed it rather than it
  returning

That last one is the point: from the outside an unexplained shutdown looks
exactly like a clean exit. `task crashes` fetches both records.

## Old note: no battery sysfs

```
$ ls /sys/class/power_supply
ls: /sys/class/power_supply: No such file or directory
```

`slot-power` reads `/sys/class/power_supply` for the battery gauge, and it does
not exist on this device. The HUD battery indicator has no source yet. Find out
how Allium reads the charge (likely an ADC under `/sys/devices` or via the MI
libraries) before writing anything.

## `task test` is `--lib` for a reason, and one integration test says why

`task test` runs `cargo test -p slot-gfx -p slot-power --lib` under qemu, so the
integration tests in `crates/slot-power/tests/` are not part of it. Running them
under qemu for the first time (2026-10-14) turned up
`the_motor_is_found_by_capability_rather_than_by_position` failing in a full
run but passing when run alone, and passing on the host either way -- test
ordering or something environmental, not armv7. It predates the backlight work.

Consequence worth knowing: the 30 tests in that file, including the PWM
backlight ones, are only exercised by a plain `cargo test -p slot-power` on the
host. Worth fixing the ordering dependency and widening `task test` to
`--lib --tests`, so they run where everything else does.

## Stock firmware: what an install needs, and it has swap (2026-10-17)

Measured on a fresh 64 GB card carrying Miyoo's own firmware, build
**202510011046** (the "20251001" download), with no launcher on it at all.

The card layout stock expects, read out of `MainUI`'s own strings rather than
guessed:

| path | what it is |
|---|---|
| `/mnt/SDCARD/miyoo285/app`, `.../lib`, `.../zoneinfo` | the firmware payload — `MainUI` reads `miyoo285/app/lang` and `miyoo285/zoneinfo/` |
| `/mnt/SDCARD/App` | where it scans for apps, `<Name>/config.json` |
| `/mnt/SDCARD/Roms`, `/Imgs`, `/Emu`, `/RApp` | its own library; slot's `Games/` is separate and stock lists none of it |

The payload belongs under `miyoo285/`, not at the root. The card is vfat and
so case-insensitive: a root `app/` *is* `App/`, and slot's entry lands among
the firmware's binaries.

**An `App/<Name>/config.json` needs an icon or stock will not list it.** The
parser reads `label`, `icon`, `iconsel`, `launch`, `description`, `autoflip`
and `noaudiofix` — it logs `add %s icon(%s) iconsel(%s) launch(%s)
autoflip(%d) noaudiofix(%d)` — and an entry carrying only label/launch/
description does not appear, with no error anywhere a user can see. That is
what the shipped v0.1.0 zip had; `card/App/*/config.json` now carries the full
set and a 120x120 `icon.png`/`iconsel.png` pair. Allium never cared, which is
why this went unnoticed for weeks.

**The card needs none of that payload to run slot** (tested 2026-10-17). With
`miyoo285/` and `miyoo285_fw.img` moved off the card entirely -- leaving slot,
its content root and `.tmp_update/runtime.sh` -- the handheld boots straight
into slot. The OS is in internal SPI flash: kernel, rootfs and `/customer`
(MainUI, libs, `axp_test`) are all there, which is why the Flip comes up with
no card at all. `main` treats the card payload as an override, `if [ -d
/mnt/SDCARD/miyoo285/ ]`, and falls back to `/customer/app/MainUI`; the
`.tmp_update/runtime.sh` hook is checked before either. The firmware `.img` is
only for flashing internal storage, once.

The clock still reads local time on such a card, and not for the reason it
looks: the tz database is **only** in the card payload -- none of the three
firmware partitions holds a `zoneinfo`, a `localtime`, or any file with the
`TZif` magic -- so `main`'s `ln -sf /mnt/SDCARD/miyoo285/zoneinfo/$timezone
/tmp/localtime` dangles and libc falls back to UTC. It agrees because the RTC
itself holds local time, and would not on a handheld whose RTC was set to UTC.

Not shipped here, and not worth the 7 MB: Allium carries no `zoneinfo` either
(zero paths in its tree) while still offering a timezone setting, so it
depends on whatever the card already has. The clock follows the RTC.

**Stock swaps.** It creates `/mnt/SDCARD/cachefile`, 128 MB, and `swapon`s it
at boot:

```
dd if=/dev/zero of=/mnt/SDCARD/cachefile bs=1M count=128;chmod 600 ...;mkswap ...
swapon /mnt/SDCARD/cachefile
```

Every memory number above it in this file was measured on Allium, which has no
swap. GBA headroom on a stock card is therefore *not* the same problem, and
the OOM work from 2026-10-16 may be unnecessary there — untested, and swapping
to a vfat SD card has its own cost in frame time. Treat it as a hypothesis
until something is measured on stock.

## The Miyoo Mini Plus, measured (2026-10-21)

The same card and the same binary as the Mini Flip, read over telnet while
slot was running on it.

| | |
|---|---|
| SoC | `INFINITY2M SSC011A-S01A-S` -- SSD202D, as the Flip |
| kernel | 4.9.84 #1136 SMP PREEMPT, built 2023-06-28 |
| panel | `/sys/class/graphics/fb0` **640x480**, 32bpp, stride 2560, `virtual_size 640,1440` -- triple buffered |
| RAM | `MemTotal 103360 kB`, the Flip's to the kilobyte |
| swap | **none** on this card (`/proc/swaps` empty) |
| power supply | no `/sys/class/power_supply`, no `/sys/class/backlight` -- PWM channel and `axp_test`, as the Flip |
| input | one node, `event0`, `soc:gpio_keys` |
| card | `/dev/mmcblk0p1` on `/mnt/SDCARD`, vfat |

slot's own line, which is the one that matters for layout:

```
slot: panel 640x480, canvas 640x480, turn None
slot: backlight pwm (0 to 112), battery axp_test, rtc0, no motor
slot: boot: shelf faces at 540 ms, input at 987 ms
```

Frame times, with `SLOT_TRACE_LATENCY` armed, which is not free:

```
in game:  work 7.3 ms, period 16.77 ms, 6 of 600 frames missed a latch
shelf:    work 13.7-24.4 ms, 57-69 of 600 missed
```

In game it is quicker than the Flip's 8.2 ms -- fewer pixels -- and the shelf
is worse, 13.7-24.4 against 15-18. Both were read with the trace writing to
the card every frame, so neither is the number this device can do; measure
again with `Config/trace-latency.txt` deleted before believing either.

**Stock's own `rcS` runs `telnetd -l sh`.** On a card with no network script
at all there is still a shell, once something brings the radio up. Here the
radio came from this port's own `net-up.sh` on the development card, not from
the device.

The panel is the only thing the port had to learn: `out_w()`/`out_h()` are
read from the framebuffer at startup (`0020`), the picture is fitted to the
width, and the console body is sized from the picture's frame. Everything
else -- audio, backlight, battery, input codes, the card scripts -- worked
unchanged from the Flip.
