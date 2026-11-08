# linux-zflip3

Mainline-based Linux on the Samsung Galaxy Z Flip3 5G (`SM-F711N`, codename `b2q`), with the
install tools and notes needed to run Arch Linux on it. Port by Noa Himesaka. Not affiliated with
Samsung.

**Status: scaffold. No device bring-up yet.** Anything marked *expected* below comes from the
stock firmware's own device tree and has not been seen working on the unit. The roadmap and the
reasoning behind each step live on the `docs` branch ([`docs/plan.md`](https://github.com/noas-slopware/linux-zflip3/blob/docs/docs/plan.md)).

## The device

Samsung Galaxy Z Flip3 5G, Korean variant `SM-F711N`, CSC `LUC` (LG U+) in the OKR multi-CSC,
shipped with Android 11 and left on One UI 7 (Android 15). That last point matters: One UI 8
removed the OEM unlocking toggle, and this model never got it, so the bootloader is still
unlockable.

| | |
|---|---|
| SoC | Qualcomm SM8350 (Snapdragon 888): 1x Cortex-X1, 3x A78, 4x A55, Adreno 660 |
| RAM / storage | 8 GB, 128 or 256 GB UFS, **no microSD** |
| Main display | 6.7" 1080x2640 foldable AMOLED, 120 Hz. *Expected* BOE panel with a Synaptics `sw43404` TDDI (display and touch in one chip), four timing sets, 2-encoder DSC |
| Cover display | 1.9" 260x512, DSI1 |
| Wi-Fi / Bluetooth | *Expected* WCN6855 (`ath11k`) |
| Battery | 3300 mAh, dual cell |
| Cellular | LG U+ never ran 3G, so this SIM is VoLTE-only. Out of scope |
| Boot chain | Stock Samsung ABL, unlockable. Non-A/B, 96 MB `boot` **and** `recovery`, Android boot header v2 with appended DTB |

## What works

"Verified" means seen working on the unit, with the date. As of 2026-11-06, nothing is.

| Subsystem | Status |
|---|---|
| Boot (ABL → mainline kernel) | not yet, M1 |
| USB device: gadget console, networking | not yet, M1–M2 |
| UFS, rootfs | not yet, M2 |
| Wi-Fi, GPU (a660/freedreno) | not yet, M2 |
| Display (main and cover) | not yet, M4 |
| Touchscreen | not yet, M4 |
| Charging, audio | not yet, M5 |
| Modem, VoLTE | out of scope |

## Boot chain

Samsung's ABL boots an Android boot image, and U-Boot sits in between
(`tools/build-u-boot.sh`, `patches/u-boot/`, `tools/mkimages.sh`):

```
ABL ──> boot      U-Boot (header v0: gzip'd U-Boot with the b2q dtb appended)
          └─────> recovery  Linux (header v2: Image.gz, initramfs, dtb, configs/cmdline)
        dtbo      24 MiB of zeros, so ABL applies no Samsung overlay to our dtb
```

U-Boot reads `recovery` from UFS and boots it. If that fails it sits in fastboot, so
`fastboot boot out/linux.img` from the host always works; holding Volume Down while it
starts opens its menu. A new kernel goes in from the running phone, with no download mode:
`tools/install-images.sh --reboot recovery=out/linux.img`.

The `recovery` slot is the bring-up slot: Android stays in `boot` until Arch works, and even after
the phone is dedicated, `recovery` keeps a rescue image that can fsck, reinstall and dump
partitions over USB.

## Roadmap

| # | Result |
|---|---|
| M0 | Unlock, evidence, EFS/persist backup, stock firmware and boot header archived |
| M1 | Our image boots from `recovery` reliably |
| M2 | UFS, USB networking, Wi-Fi, GPU: `ssh` into the phone |
| M3 | Arch Linux Ports aarch64 rootfs, `pacman -Syu` over that ssh |
| M3.5 | Wipe and dedicate: `super` → `/`, `userdata` → `/home`, no GPT surgery |
| M4 | Display + touch: 60 Hz first, then 120 Hz |
| M5 | Charging, audio (stretch) |

### Next

- Fold: closing suspends and opening wakes (done); still to do is the cover display
  while closed.
- Power and volume keys handled by Plasma Mobile (lock and sleep) instead of logind's poweroff.
- Misc sensors (skipped for now).
- Battery: AFC 9 V needs a test with a Samsung AFC brick; QC 2.0 and PPS not ported.
- Cellular.

### For the rootfs rebuild

Done by hand on the phone and not yet in `tools/build-rootfs.sh`; it goes in once
everything, cellular included, works:

- packages beyond `ROOTFS_PACKAGES`: `mesa mesa-utils plasma-mobile plasma-login-manager
  plasma-settings qmlkonsole bluedevil kscreen firefox feedbackd evtest i2c-tools` (plus the
  Adreno zap shader), later `plasma-dialer spacebar` with cellular,
- user `mogumo` (groups wheel, video, audio, input, render), no password set by the
  build, and `plasmalogin.service` enabled; the autologin and `LockOnStart` files are
  already in `userspace/rootfs/etc/`, so the first screen is Plasma Mobile's lock screen,
- mobile-config-firefox 5.5.0 with the four Fenix patches from linux-hiby-rs6
  (`patches/mobile-config-firefox/`), `make install` into `/`.

### Far future

- **96 and 48 Hz on the main panel.** Stock's VRR sets switch the S6E3HAD to 96HS, 48HS and
  48NS live (measured over debugfs: TE 96 / 48 / 49), but stock also corrects the gamma at
  those rates with values computed from the panel's flash, so the driver leaves them out.
  Porting it means `ss_gm2_gamma_comp_init()` in Samsung's
  `ss_dsi_panel_S6E3HAD_AMF670ZA01.c`: the flash reads of the HS120 HBM and normal gamma,
  `MTP_OFFSET_96HS_VAL_revC` (this unit is rev D) and `aor_table_96` /
  `aor_table_120`. Measurements are in `evidence/SM-F711N-m0.md`, section "The main panel is
  S6E3HAD_AMF670ZA01 rev D".

## Repository

| branch | contents |
|---|---|
| `senpai` | `patches/`, `tools/`, `userspace/` — the port |
| `docs` | write-ups: plan, boot chain, panel, storage, cellular, evidence policy |
| `firmware` | vendor firmware extracted from the stock firmware before the wipe |

```
patches/linux/      numbered series against sources.lock's LINUX_VERSION
tools/              host-side: extract firmware, build kernel, pack and flash boot images
userspace/          on-device: bring-up initramfs, installer
```

## Quickstart

```sh
# 1. M0: get the stock firmware, then pull it apart
tools/fetch-firmware.sh --list                  # F711NKSSFKZH5 for LUC right now
tools/fetch-firmware.sh                         # about 8 GB into .cache/fw
tools/extract-firmware.sh .cache/fw/AP_*.tar.md5

# 2. M0: record the device state before touching anything (needs adb)
tools/evidence.sh

# 3. build a kernel from the pinned base plus patches/linux
tools/fetch-kernel.sh          # download + verify the pinned base
tools/build-kernel.sh --apply  # configs/nura-sm8350.config + configs/b2q.fragment + patches

# 4. U-Boot, the bring-up initramfs, and the images
tools/build-u-boot.sh
tools/build-busybox.sh
tools/build-initramfs.sh --busybox out/busybox --rootfs out/rootfs --out out/initramfs.cpio.gz
tools/mkimages.sh

# 5. first install, from download mode (heimdall, on the machine the phone is plugged into)
B2Q_UNLOCKED=1 tools/flash.sh --partition dtbo --image out/dtbo-empty.img \
                              --partition boot --image out/boot.img \
                              --partition recovery --image out/linux.img

# afterwards, from the running phone
tools/install-images.sh --reboot recovery=out/linux.img
```

USB enumerates only after the cable is re-plugged once the kernel runs; the shell is then on
`ttyACM0`. `tools/flash.sh` refuses to run until `B2Q_UNLOCKED=1` says the device is unlocked
and the stock firmware is saved.

## Licenses

See [LICENSES/README.md](LICENSES/README.md). The kernel patches are GPL-2.0-only, everything in
`tools/` and `userspace/` is MIT.
