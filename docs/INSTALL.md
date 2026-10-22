# installing slot on a Miyoo Mini Flip, Mini Plus or Mini

This is the short version. The [README](../README.md) is the development log and
explains *why*; this page is just what to do.

You need: the handheld, its SD card, a computer with a card reader, and a
`slot-miyoo-*.zip` from [Releases](https://github.com/deanmarano/slot-miyoo/releases)
(or `task release`, if you are building it yourself).

**One zip covers the Mini Flip, the Mini Plus and the Mini.** slot reads the
panel from the framebuffer when it starts -- 752x560 on the Flip, 640x480 on
the other two -- so the same card runs on any of them, and moving it between
them is all it takes.

Nothing here reflashes the device, deletes anything, or replaces your launcher.
slot installs beside it as one more app, and works on stock firmware as well as
on Onion or Allium — no custom firmware is required to run it.

It is tested on the **Mini Flip** with **stock Miyoo firmware** (build
202510011046) and with **Allium**, on the **Mini Plus** with both stock and
Allium, and on the **Mini** with **Onion** 4.3.1. Onion gets the same launcher entry as stock and the same binary, and
nothing in the launch path depends on a particular firmware, but nobody has
booted it on Onion yet. On the Mini Plus and the Mini, the menus,
saves and states have had a poke rather than a session -- see
[docs/PORTING.md](PORTING.md).

## 0. if the card is blank

Skip this if your card already boots the handheld.

A blank card will not boot: the Flip loads its OS from the card. Format it
**FAT32** -- not exFAT, which the launcher cannot read -- then install Miyoo's
own firmware before slot. Get it from
[lomiyoo's firmware page](https://lomiyoo.com/pages/firmware), Mini Flip entry,
and unzip the inner `miyoo285.zip` into a **`miyoo285/` directory** on the card
rather than at the root: `MainUI` reads `/mnt/SDCARD/miyoo285/app/lang` and
`/mnt/SDCARD/miyoo285/zoneinfo/`, and `/mnt/SDCARD/App` is a separate place it
scans for apps. On a case-insensitive card an `app/` at the root *is* `App/`,
and slot's entry ends up buried among the firmware's own files.

Put `miyoo285_fw.img` at the card root, plug the handheld into its charger
first, then switch it on; it updates itself and reboots. If no rocket appears,
power off, hold MENU, and plug the charger in while still holding. Check the
build in Settings afterwards. The update writes internal storage and leaves the
card alone, so slot can go on before or after it.

Once the handheld's firmware is up to date, **a card needs none of that to run
slot**: the OS lives in the handheld, not on the card, and a FAT32 card holding
only slot's zip boots fine. The clock then follows the handheld's own RTC,
since nothing on such a card carries a timezone database -- Allium does not
ship one either.

## 1. back up the card

The stock firmware is particular and a known-good copy costs nothing. Copy the
whole card somewhere before you start. If you skip one step on this page, don't
let it be this one.

## 2. unzip into the card root

Put the card in your computer. The **card root** is the directory holding
`Roms/` and `Apps/` — the one the handheld sees as `/mnt/SDCARD`.

Unpack the zip so its contents land *in* that directory, not in a subfolder of
it. You should end up with `System/slot` on the card, not
`slot-miyoo-v0.2.0/System/slot`.

```sh
unzip -d /media/you/MIYOO slot-miyoo-v0.2.0.zip
sync
```

It merges: `Apps/` and `App/` gain slot's entries, `System/` gains the binary
and the launch scripts, and the content root slot expects is created empty.
Nothing already on the card is removed.

Then eject the card properly — `sync` above, and unmount before pulling it.

## 3. put the card back and find slot

Boot the handheld. slot appears in the app list — **Apps → slot** on Allium,
**App → slot** on stock firmware or Onion. The zip carries an entry in both
layouts and the launcher you are not using ignores the other, so there is
nothing to choose and no custom firmware to install first: slot runs as an
app like any other.

**If it isn't there, reboot once more.** The launcher caches its app list, and
the first boot after adding files often doesn't show them.

## 4. games and the GBA BIOS

ROMs go **unzipped** in the folders the zip created:

| system | folder |
|---|---|
| Game Boy | `Games/GB` |
| Game Boy Color | `Games/GBC` |
| Game Boy Advance | `Games/GBA` |

These are slot's own folders and are **not** the `Roms/` your launcher uses —
slot keeps its library separate. Saves and save states land beside them in
`Saves/` and `States/`.

GBA also needs a BIOS at **`BIOS/gba_bios.bin`**. Without it GBA games will not
start. It is not included here and you have to supply it yourself.

Bezels -- the plastic body drawn around the picture -- are picked per console
in the quick menu under Screen. A Game Boy and a Game Boy Color body ship
inside slot itself; the Advance SP shell is `System/bezels/640x480.png`. Your
own art goes in **`Bezels/GB`** or **`Bezels/GBC`** as a PNG, 720x480 with a
transparent hole where the picture belongs, and appears in that menu by its
file name.

## 5. the controls worth knowing

| gesture | what it does |
|---|---|
| **hold MENU ~1 s** | **eject the cart, back to the shelf** |
| tap MENU, on the shelf | quick menu |
| tap MENU, in a game | the in-game menu: screen, bezels, palettes, states |
| double-tap MENU, in a game | straight to States |
| hold POWER ~1 s | power menu |
| L1 / R1 in a GB or GBC game | stretch / actual size |
| **START on the shelf, GBA cart selected** | core picker: left = mGBA, right = **gpSP** |

**For GBA, pick gpSP.** mGBA interprets on this CPU and runs at roughly half
speed; gpSP has an ARM JIT and holds the frame budget. The choice is per game.

slot boots straight back into whatever cart was last in the slot — that is
deliberate, not a fault. Eject to get the shelf back.

## if something is wrong

slot writes **`Logs/slot.log`** on the card. Read it first; it says what it was
doing when it stopped. Then:

| symptom | likely cause |
|---|---|
| no slot in the app list | launcher cache — reboot again |
| GBA games won't start | no `BIOS/gba_bios.bin` |
| a GBA game runs at half speed | mGBA is selected; switch to gpSP |
| MENU draws a hotkey bar over the game | that is your launcher's overlay, not slot. Known, see the README |
| the screen looks off at boot | brightness is low, not broken — raise it in the menu |
| nothing on screen at all | check `Logs/slot.log`, and that `System/slot` really is on the card |

The battery indicator and the lid both work: closing the lid saves, darkens the
panel and powers off after three minutes.

## going further

- **booting straight into slot.** On stock firmware this is one file: copy
  `System/autoboot/runtime.sh` from the zip to **`.tmp_update/runtime.sh`** at
  the card root. The handheld then comes up in slot instead of MainUI; delete
  that file and stock comes back, both doable with the card in a computer.
  Stock's `/customer/main` runs `.tmp_update/runtime.sh` on every boot and
  leaves it there, where a `.tmp_update/updater` is run once and the directory
  deleted — which is why this is a `runtime.sh`.

  **Do not do this on an Allium or Onion card.** They boot through that same
  file and this would replace theirs; see
  [the port log](../notes/port-log.md#booting-straight-into-slot) for the Allium route.
- [working over the network](../notes/port-log.md#working-over-the-network-instead-of-moving-the-card)
  — WiFi, telnet and FTP for pushing new builds without moving the card. Not in
  the zip: it needs a launcher's own wifi script, and the only way to give it a
  password is to type one into a file on the card.
- [two-player link](link.md) — written, not yet played.

slot is by [Brandon Kowalski](https://github.com/BrandonKowalski/slot). This is
an unofficial port; please don't send slot's issue tracker Miyoo bugs.
