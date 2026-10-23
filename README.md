# slot on the Miyoo Mini Flip

[**slot**](https://slot-cfw.fyi/) is Brandon Kowalski's Game Boy frontend for
the Anbernic RG SP: you pick a cartridge off a shelf and push it into a
console. This is an unofficial port of it to the **Miyoo Mini Flip**, a
clamshell handheld with two Cortex-A7s, 101 MB of usable RAM and **no GPU at
all** — so everything you see is drawn on the CPU.

![slot's shelf on the handheld, drawn entirely on the CPU](docs/shelf.png)

It plays Game Boy, Game Boy Color and Game Boy Advance games on real hardware,
with saves, save states, rewind, sleep-on-close and a console body drawn around
the picture.

The same binary runs on the **Miyoo Mini Plus** and the **Miyoo Mini** too —
the same GPU-less SigmaStar SoC with a 640x480 panel, which it reads from the
framebuffer at startup rather than having compiled in.

## install it

Download the latest `slot-miyoo-*-flip.zip` from
[Releases](https://github.com/deanmarano/slot-miyoo/releases), unzip it into
the root of your SD card, and find **slot** in your launcher's app list.

That's the whole install — it needs no custom firmware and replaces nothing.
It works on Miyoo's own firmware as well as on Allium, and your games go in
`Games/GB`, `Games/GBC` and `Games/GBA` on the card.
[**docs/INSTALL.md**](docs/INSTALL.md) is the full page: BIOS files, bezels,
booting straight into slot, and what to do when something is wrong.

| | |
|---|---|
| **hold MENU ~1 s** | **eject the cart, back to the shelf** |
| tap MENU | the menu — screen, bezels, palettes, save states |
| double-tap MENU in a game | straight to States |
| hold POWER ~1 s | power menu |
| L1 / R1 in a GB or GBC game | stretch / actual size |
| **START on the shelf, GBA cart** | **core picker — pick gpSP for GBA** |

slot comes back up in whatever cart was last in the slot. That's deliberate;
eject to get the shelf back.

## what works

Everything here was seen running on the handheld, not inferred from a build.

| | |
|---|---|
| GB, GBC, GBA | yes — GBA on gpSP, which has an ARM JIT; mGBA plays all three |
| frame budget | backend 8.2 ms of a 16.86 ms frame, core 6.3 ms |
| shelf | scrolls at 15-18 ms a frame |
| saves, save states, rewind | yes, including MBC2's odd 512x4 bits |
| big carts | 32 MB ROMs (Mother 3) play on both cores |
| bezels | a Game Boy, Color or Advance SP body per console |
| GB palettes | 48 of them, off by default — turn on under Screen, then L2/R2 |
| lid | closing it saves, darkens the panel, powers off after 3 min |
| buttons | all 18, including the d-pad |
| battery | yes, read from the vendor's `axp_test` |
| audio | yes, via SigmaStar `MI_AO`; sits ~100 ms behind the picture |
| **two-player link** | **written, never played — assume it doesn't work** |

Sixteen carts have been played through on the device across the three
platforms. The install path is tested on stock firmware (build 202510011046)
and on an Allium card; nobody has tried Onion. Memory is comfortable rather
than generous: a 32 MB cart with rewind on leaves about 15 MB free.

![a Game Boy game inside its own console body](docs/bezel.png)

## how it relates to upstream

Upstream lives in `upstream/slot` as a **pinned, read-only submodule**. Every
change this port makes to upstream files is a patch in `patches/`, applied to
that working tree by `task patch`; a patch that no longer applies is a hard
error, so an upstream bump cannot quietly drop one. The submodule was last
bumped on 2026-10-22, to upstream **`v1.8.1`**.

The port is feasible because `slot-ui` makes no graphics calls at all — it
emits a display list of six `Draw` variants, and all the GL sits behind one
`Surface` trait. Upstream has two backends, a desktop window and GLES2 on
`/dev/fb0`; the port adds a third, a software rasteriser writing to a mmapped
framebuffer. Nothing above that seam changed.

The twenty-five patches, by what they are about:

| | |
|---|---|
| the renderer | `0002` software backend, `0024` the game drawn when the direct path cannot, `0025` the shell told to the game, `0026` the shell out of the frame and blue light in the mask, `0009` picture size, `0012`/`0013` bezels, `0015` cart compositing |
| armv7 | `0001` crash registers, `0004` 32-bit evdev bitmaps |
| device hardware | `0003` button codes, `0005` `MI_AO` audio, `0008` PWM backlight, `0010` battery source |
| memory | `0016` cart faces, `0017` rewind sizing, `0018` texture frees, `0019` `need_fullpath` |
| timing | `0011` cart-face wait, `0014` animation step clamp |
| panels | `0020` the layout sized from the panel at runtime, so one binary fits the Flip's 752x560 and the Mini and Mini Plus's 640x480 |
| the Mini | `0021` volume handed to its wheel, `0022` its battery read off the SAR ADC |
| these devices | `0007` the sticker, `0023` the handheld's own name on it |

`0019` and `0014` are not about this device and belong upstream;
`notes/upstream-perf-issue.md` is the issue drafted for them.

## build it

Needs Docker and [go-task](https://taskfile.dev). One image cross-builds the
Rust frontend and both C cores for armv7 against the device's own glibc 2.28.

```sh
git clone --recurse-submodules https://github.com/deanmarano/slot-miyoo
cd slot-miyoo

task            # list every task
task all        # cores + frontend for armv7, from a clean tree
task release    # the zip a user installs -> ./release
task run:qemu   # run the device build on this machine, under qemu
task shell      # poke around inside the toolchain container
```

`task all` produces three armv7 artifacts: the 4.0 MB `slot` frontend and the
`gpsp` and `mgba` libretro cores, all 32-bit ARMv7-A, VFPv4 hard-float, needing
nothing beyond glibc 2.28. With a device on the network, `task deploy` pushes
a build over FTP and `task log` pulls the log back.

```
card/        what ships on the SD card — launcher entries and launch scripts
cores/       armv7 build scripts for the two libretro cores
patches/     changes to upstream files, applied to the submodule
toolchain/   the cross build box
tools/       fb2png, the wordmark generator, the telnet one-liner
upstream/    pinned submodule, read-only
```

A host build or a passing unit test proves nothing about this device, and
`task run:qemu` runs the real binary but on the wrong machine — it says nothing
about frame times or the 101 MB ceiling.

## where to read next

- [**docs/PORTING.md**](docs/PORTING.md) — where every device-specific part
  lives, for getting slot onto another handheld. The Mini Plus and Mini are the
  same GPU-less SoC as this one.
- [**notes/port-log.md**](notes/port-log.md) — how the port works and why,
  patch by patch, plus what is still open.
- [**notes/hardware.md**](notes/hardware.md) — everything measured off the
  device: the panel, the frame budget, the full button map, the traps.
- [**CLAUDE.md**](CLAUDE.md) — how to work in this repo.
- [**docs/link.md**](docs/link.md) — two-player, as far as it got.
- [**notes/variants.md**](notes/variants.md) — the other Miyoo models.

## credit and licence

slot is by [Brandon Kowalski](https://github.com/BrandonKowalski/slot) and is
GPL-3.0-or-later; this port inherits that. It is unofficial and unaffiliated —
please don't send slot's issue tracker bugs about a Miyoo. The sticker in the
app says as much, for anyone who reads the device before the README.
