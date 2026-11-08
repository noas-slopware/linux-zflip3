# linux-zflip3

Mainline-based Linux on the Samsung Galaxy Z Flip3 5G (`SM-F711N`, codename `b2q`), with the
install tools and notes needed to run Arch Linux on it. Port by Noa Himesaka. Not affiliated with
Samsung.

**Status: daily-usable bring-up.** Arch Linux Ports with Plasma Mobile runs from UFS with
display, touch, Wi-Fi, Bluetooth, GPU, charging, speakers, microphone, cellular data, SMS,
MMS and VoLTE calls. Not yet: waking from suspend for an incoming call or SMS, the earpiece,
DTMF, the cameras and hardware video decode, the cover display, the fingerprint sensor,
motion and environment sensors, NFC, GNSS, wireless charging, the camera flash, and the
hinge angle beyond open/closed. [`STATE.md`](STATE.md) has the details. The roadmap and the reasoning behind
each step live on the `docs` branch ([`docs/plan.md`](https://github.com/noas-slopware/linux-zflip3/blob/docs/docs/plan.md)).

## The device

Samsung Galaxy Z Flip3 5G, Korean variant `SM-F711N`, CSC `LUC` (LG U+) in the OKR multi-CSC,
shipped with Android 11 and left on One UI 7 (Android 15). That last point matters: One UI 8
removed the OEM unlocking toggle, and this model never got it, so the bootloader is still
unlockable.

| | |
|---|---|
| SoC | Qualcomm SM8350 (Snapdragon 888): 1x Cortex-X1, 3x A78, 4x A55, Adreno 660 |
| RAM / storage | 8 GB, 128 or 256 GB UFS, **no microSD** |
| Main display | 6.7" 1080x2640 foldable AMOLED, 120 Hz: Samsung S6E3HAD AMF670ZA01 (rev D on this unit), touch on a separate STMicroelectronics FTS9CU80F |
| Cover display | 1.9" 260x512, DSI1 |
| Wi-Fi / Bluetooth | QCA6390 over PCIe (`ath11k`), Bluetooth over UART |
| Battery | 3300 mAh, dual cell |
| Cellular | SM8350 modem (mpss) over QRTR/IPA. LG U+ never ran 3G, so calls and SMS are IMS only: VoLTE and SMS over IMS through our own userspace IMS stack (`userspace/imsd`) |
| Boot chain | Stock Samsung ABL, unlockable. Non-A/B, 96 MB `boot` **and** `recovery`, Android boot header v2 with appended DTB |

## What works

"Verified" means seen working on the unit. Kernel 7.3.1 build #57, 2026-11-09.

| Subsystem | Status |
|---|---|
| Boot (ABL → U-Boot → mainline kernel) | verified |
| USB device: gadget console, networking | verified |
| UFS, rootfs (Arch Linux Ports aarch64) | verified |
| Wi-Fi, Bluetooth, GPU (a660/freedreno) | verified |
| Main display, touchscreen | verified (cover display not yet) |
| Fold sensor: closing suspends, opening wakes | verified |
| Charging, dual cells, fuel gauge | verified |
| Speakers, microphones | verified (earpiece not yet) |
| Cellular data (LG U+ LTE, IPv6 + CLAT) | verified |
| IMS registration (ISIM AKA) | verified |
| SMS send and receive, received while ModemManager or the phone was down | verified |
| MMS send and receive (Spacebar) | verified |
| VoLTE calls in and out, to and from other networks, AMR-WB / AMR-NB | verified |

## Not working yet

"Not started" means there is no driver, no DT node, or no userspace integration in this tree,
not that the hardware is broken on this unit.

| Subsystem | State |
|---|---|
| Incoming call or SMS waking the phone from suspend | not yet: delivered at the next wake |
| Earpiece during calls | calls play on the speaker; no Voice Call UCM profile yet |
| Emergency and supplementary calls | DTMF is never sent; call waiting, hold and conference are not implemented |
| Wi-Fi calling (VoWiFi) | not implemented |
| 5G NR | the modem reports the capability; data and voice have only been verified on LTE |
| Cameras (rear 12 MP wide + 12 MP ultrawide, front 10 MP) | not started: no sensor, CCI or CAMSS nodes |
| Hardware video decode and encode (qcom-iris) | nodes exist but firmware load fails, so no VA-API and no V4L2 decode |
| Camera flash and torch | no LED driver |
| Fingerprint sensor in the power button | not started: the pins are TZ-owned, see `STATE.md` |
| Accelerometer, gyro, magnetometer, proximity, ambient light | not started: no IIO drivers or DT nodes |
| NFC | not started: the GPIO names are reserved only, there is no PN553/SN100 node |
| GNSS | not started: no GNSS driver or modem LOC integration |
| Cover display | not driven; only the main S6E3HAD panel is |
| USB host/OTG | untested |
| Wireless charging and reverse wireless charging | not ported; the WPC GPIOs are named but unused |
| Hinge angle | only open/closed via `SW_LID`, no angle sensor |
| Bluetooth audio (A2DP/HFP) and USB-C audio | untested |
| Idle power, thermal limits, charge curves | not tuned; QC 2.0, PPS and wireless charging are not ported |
| RTC alarm waking from suspend | untested |

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

Priority order for a daily driver:

- Incoming calls and SMS waking the phone from suspend: the IPA wakeup source never fires.
- Earpiece during calls, then Bluetooth and USB-C audio.
- DTMF, call waiting, hold, conference, and emergency calls.
- Modem recovery after suspend, airplane mode or a modem crash.
- Cameras and hardware video decode, both Iris work: CAMSS/CCI, the three sensors and the
  flash LED, then the iris firmware loading and VA-API.
- Fingerprint sensor.
- Motion and environment sensors, so auto-rotate, proximity and auto-brightness work.
- NFC and GNSS.
- Cover display while folded.
- Wireless charging, QC 2.0, PPS, thermal limits and idle drain.
- Power and volume keys handled by Plasma Mobile (lock and sleep) instead of logind's poweroff.
- The rest of the list in `STATE.md`.

### For the rootfs rebuild

Done by hand on the phone and not yet in `tools/build-rootfs.sh`; it goes in once
everything, cellular included, works:

- packages beyond `ROOTFS_PACKAGES`: `mesa mesa-utils plasma-mobile plasma-login-manager
  plasma-settings qmlkonsole bluedevil kscreen firefox feedbackd evtest i2c-tools plasma-dialer`
  (plus the Adreno zap shader),
- the cellular stack built on the phone: `b2q-imsd` from `userspace/imsd/packaging`,
  ModemManager with `patches/modemmanager/`, Spacebar from `userspace/spacebar` with
  `patches/spacebar/`, and `opencore-amr` plus `vo-amrwbenc` for the call codecs,
- the audio bits: `tools/extract-amp-firmware.sh` output in `/usr/lib/firmware/cirrus/`,
  the UCM files under `userspace/rootfs/usr/share/alsa/ucm2/`, the WirePlumber drop-in
  under `userspace/rootfs/etc/wireplumber/`, and the CS35L41 module once the 15 ms
  mailbox build is final,
- the IMS runtime directories: `/var/lib/b2q-imsd/inbox` and `/run/b2q-imsd` for the
  durable SMS inbox and the call audio socket,
- the Spacebar MMSC default for `<user>` (`http://omammsc.uplus.co.kr:9084`,
  no proxy) so a reimage can send MMS without opening settings,
- user `<user>` (groups wheel, video, audio, input, render), no password set by the
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
| `senpai` | `patches/`, `tools/`, `userspace/`: the port |
| `docs` | write-ups: plan, boot chain, panel, storage, cellular, evidence policy |
| `firmware` | vendor firmware extracted from the stock firmware before the wipe |

```
patches/linux/           numbered series against sources.lock's LINUX_VERSION
patches/u-boot/          SM8350 and b2q support for U-Boot
patches/modemmanager/    b2q-imsd backend for voice and messaging
patches/spacebar/        MMS send, own number and duplicate fixes
patches/plasma-keyboard/ Korean composition, content types
tools/                   host-side: extract firmware, build, pack, flash and install images
userspace/installer/     bring-up initramfs and installer
userspace/rootfs/        files the rootfs carries on top of the distribution
userspace/imsd/          IMS bearer, IMS daemon (VoLTE, SMS, MMS) and the call audio bridge
userspace/spacebar/      PKGBUILD for the patched Spacebar
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
