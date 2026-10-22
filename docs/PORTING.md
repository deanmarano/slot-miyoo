# porting this to another handheld

This port runs slot on a device with **no GPU**, by replacing one trait. If you
are trying to get slot onto a different handheld, this page is the map of
where the device-specific parts live, so you do not have to read the whole
[port log](../notes/port-log.md) to find them.

Everything here is a patch in `patches/`, applied to the pinned submodule by
`task patch`. Upstream's own tree is never edited.

## the seam

`slot-ui` makes no graphics calls. It emits a list of `Draw` variants, and
every GL call sits behind the `Surface` trait in
`upstream/slot/crates/slot-gfx/src/surface.rs`. Upstream has two backends,
chosen by cargo feature: `host` (winit + glutin, a desktop window) and
`device` (`fbdev.rs`, dlopen `libEGL.so` and GLES2 on `/dev/fb0`).

This port adds a third, `software` — a CPU rasteriser over a mmapped
`/dev/fb0` — and changes nothing above the seam. **If a change needs editing
`slot-ui`, it almost certainly belongs in the backend instead.**

## where device coupling lives

| concern | file | patch | notes |
|---|---|---|---|
| panel size | `slot-gfx/src/surface.rs` (`out_w()`/`out_h()`) | `0009`, `0020` | the canvas *is* the panel here, and it is read from the framebuffer at startup by `set_panel_size`. 752x560 on a Mini Flip, 640x480 on a Mini Plus, one binary |
| picture size and fit | `slot-gfx/src/pipeline.rs` (`SCALE`, `SRC_W`, `SRC_H`) | `0009` | 3x actual size, height-filling stretch |
| the rasteriser | `slot-gfx/src/soft/` — `mod.rs`, `raster.rs`, `fb.rs` | `0002` | ~3,200 lines. `fb.rs` owns the framebuffer and the page flip |
| framebuffer format | `slot-gfx/src/soft/fb.rs` | `0002` | XRGB8888 here, triple buffered. A 16bpp panel needs work in `blit` |
| panel orientation | `card/System/launch_frontend.sh` (`SLOT_FB_ROTATE`) | — | the Mini Flip's LCD is fitted upside down; 180 is set there, not in code |
| button codes | `slot/src/input/evdev.rs` (`code_to_btn`) | `0003` | behind the `miyoo` cargo feature. This device reports *keyboard* codes, not gamepad ones |
| evdev ioctl width | `slot/src/input/evdev.rs` | `0004` | 32-bit userland: the key bitmap is `u32`, not `u64` |
| lid / hall sensor | `slot/src/input/device.rs` | `0003` | an evdev node advertising `KEY_POWER`. Upstream expects a `hallkey` file under `/sys/class/power_supply`, which does not exist here |
| backlight | `slot-power/src/device.rs` | `0008` | a PWM channel, not a backlight class device. Ten steps, non-linear |
| battery | `slot-power/src/device.rs` | `0010` | `/customer/app/axp_test`; there is no `/sys/class/power_supply` at all |
| audio | `shim/slotao.c` + `slot/src/audio/` | `0005` | SigmaStar `MI_AO` through a dlopened shim, because ALSA is not the real path |
| launcher entries | `card/App/`, `card/Apps/` | — | `App/<Name>/config.json` for stock and Onion, `Apps/<Name>.pak/` for Allium |
| boot hook | `card/System/autoboot/runtime.sh` | — | stock firmware runs `.tmp_update/runtime.sh` every boot |
| cross toolchain | `toolchain/Dockerfile`, `taskfile.yml` | — | armv7, glibc 2.28, Rust 1.96; `GFX: software` picks the backend |
| cores | `cores/gpsp/build-miyoo.sh`, `cores/mgba/` | — | gpSP has an ARM dynarec and is the one to use for GBA |

## what a new device actually needs

In rough order of how much work each is.

1. **A toolchain and a libc floor.** `task glibc` prints the highest glibc
   version the built binary needs; the device must be at least that. Ours is
   2.28, which is the Miyoo Mini community toolchain's.
2. **The panel.** `OUT_W`/`OUT_H` and the framebuffer format. If the panel is
   16bpp or a different byte order, `soft/fb.rs` and `raster::blit` are where
   that lives. A panel that is not close to 4:3 will also want
   `bezel::framed`'s tolerance looked at (`0012`).
3. **Buttons.** Run the probe (`task probe`) or `SLOT_TRACE_INPUT=1` and read
   the codes off the device, then add a `code_to_btn` arm behind a feature.
   Do not guess them from another device's map.
4. **Power.** Backlight and battery are the two that are never where slot
   expects. Check what exists under `/sys/class` before writing any code:
   this device had neither a backlight class device nor a power supply.
5. **Audio.** If ALSA works, nothing to do. If the SoC wants a vendor API, the
   shim is the pattern: a small `.so` slot dlopens, so the Rust build needs no
   vendor SDK.
6. **The launcher.** Whatever starts apps on that firmware. Start slot through
   the dynamic loader (`/lib/ld-linux-armhf.so.3 .../slot`) rather than
   executing it — cards are routinely mounted `noexec`.

## other SigmaStar devices

The **Miyoo Mini Plus** runs this, tested 2026-10-21: the same card and the
same binary as the Mini Flip, reading its 640x480 panel at startup. Games
play, with sound, the console bodies and the Advance SP shell drawn right.
What has *not* been checked there: GBC, the menus, buttons beyond play, saves
and states, a clean install on stock firmware, and a frame time measured
without the latency trace armed.

The **Miyoo Mini** is the same SoC and panel again, and untried.

The **Miyoo A30** is not the same machine: an Allwinner A33 with a Mali-400
and 512 MB, so it can run upstream's own GLES2 backend and wants none of this
rasteriser. The audio, backlight and battery patches here are SigmaStar's and
would not apply either.

`notes/hardware.md` is measured on a Mini Flip except where it says otherwise;
treat every number in it as a hypothesis on another device until it has been
read off that device.

Upstream's `fbdev` backend is the one to use on anything that *does* have
GLES2. The software path is slower by a wide margin and exists because this
SoC leaves no alternative.

## two things that cost us days

- **Time a sleep before trusting it.** `CONFIG_HZ` is 100 on these kernels, so
  a few-millisecond `thread::sleep` can return a tick late. Three separate
  "slow" bugs were that one fact.
- **Measure memory before fixing it.** 101 MB usable, no swap on Allium, and a
  GBA core wants most of it. Five separate causes of pressure were found by
  reading `/proc/<pid>/smaps` with a core loaded, after three "fixes" that
  freed nothing.
