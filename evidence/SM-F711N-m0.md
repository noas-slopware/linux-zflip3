# M0 device dump, 2026-11-06

Sanitised summary of the read-only evidence pull (`tools/evidence.sh`). Raw dumps are in
`evidence/device/<timestamp>/`, which is gitignored because they carry the device serial.

## Identity

| | |
|---|---|
| model | SM-F711N |
| codename / product | `b2q` / `b2qksx` (Korean, LUC sales code) |
| CSC | LUC (LG U+), OKR multi-CSC |
| build | `F711NKSSFKZH5`, Android 15 / One UI 7 (`AP3A.240905.015.A2`) |
| security patch | 2026-08-05 |
| baseband | `msm` (integrated Snapdragon 888 modem) |

## Unlock gate

| | | verdict |
|---|---|---|
| OEM unlocking (Developer options) | on | ok |
| `knox.kg.state` | `Completed` | ok, not Prenormal |
| `ro.boot.flash.locked` | `1` | **still locked** |
| `ro.boot.verifiedbootstate` | `green` | still verified boot |
| `ro.boot.warranty_bit` | `0` | Knox not tripped yet |

So the toggle is on and nothing blocks the unlock, but the bootloader itself has not been
unlocked. That happens in download mode with a long press, and it wipes userdata. Expect
`verifiedbootstate` to become `orange` and `warranty_bit` to stay `0` until the first
non-stock image boots (it flips to `1`).

## Storage layout (measured, 256 GB model)

| partition | device | size |
|---|---|---|
| `boot` | sda19 | 96 MiB |
| `recovery` | sda20 | 96 MiB |
| `vendor_boot` | sda21 | 96 MiB |
| `dtbo` | sda22 | 24 MiB |
| `metadata` | sda25 | 16 MiB |
| `super` | sda26 | 14040 MiB |
| `userdata` | sda37 | 227206 MiB |
| `efs` | sda6 | 20 MiB |
| `persist` | sda5 | 32 MiB |
| `param` | sda7 | 10 MiB |

Two surprises against the LineageOS `b2q` device tree:

1. `super` is 13.7 GiB here, not the 12067012608 bytes (11.2 GiB) that tree declares.
   Firmware grew it. The storage plan uses it as `/`, so the larger size is good news.
2. There is a **`vendor_boot`** partition. The Android 11-era tree builds a header v2
   `boot.img` with the kernel and ramdisk inside, and no vendor_boot. Whether ABL on this
   firmware wants anything from `vendor_boot` is an M1 question; the stock image's own
   `mkbootimg` arguments (from `tools/extract-firmware.sh`) will settle it either way.

## Not readable without root

`/proc/cmdline` is `Permission denied` on Android 15. The ABL command line therefore has to
come from the stock `boot.img` header (M0 extraction) rather than from the running system.

## The boot chain is header v3 with the dtb in vendor_boot

Unpacking the stock AP tar (F711NKSSFKZH5) corrects what the LineageOS `b2q` tree implies:

| image | header | contents |
|---|---|---|
| `boot.img` | v3 | kernel, ramdisk (723409 B), command line, **no dtb** |
| `vendor_boot.img` | v3 | **dtb (1433155 B)**, vendor ramdisk (695382 B), `board = SRPUC29A015` |
| `dtbo.img` | — | 7 overlays, 24 MiB; panel definitions live here |

So M1 is two images, not one:

- `boot.img`: v3, our kernel + our initramfs, no dtb
- `vendor_boot.img`: v3, our dtb + a (possibly empty) vendor ramdisk

The board string on this firmware is `SRPUC29A015`, not the `SRPUC03A002` the old
LineageOS tree hardcodes, which is exactly why `tools/bootimg.sh` reads it from the stock
image instead.

The dtb only carries the platform (`chosen { bootargs = "log_buf_len=256K ..." }`, no
panel nodes); every panel variant is in the dtbo overlays, and the phone picks one at
runtime by reading the panel ID. Candidates found in the overlay, all present in all 7
entries:

- `sw43404 amoled ... boe panel with DSC` (the Synaptics TDDI one)
- `ss_dsi_panel_S6E3HAD_AMF670ZA01_FHD` and `S6E3HA9_AMF670UH01_FHD` (Samsung DDICs)
- `r66451 amoled ... visionox`, plus the cover panels `S6E36W3 ... 260X488` and `116X300`

Which one is actually in this unit is not yet known: `/sys/class/lcd/panel` is root-only,
so it needs either root or the first Linux boot to read the DDIC ID. Not needed before M4.

## Display modes, from the running system

`dumpsys display` on the stock ROM reports the main panel as 1080x2640 with modes 120 /
96 / 60 / 48 Hz and HDR types 2/3/4; the cover is 512x260 at 60 Hz. That matches the
`fhd*` timing sets in the overlay, with 48 Hz as an extra alternative rate.
