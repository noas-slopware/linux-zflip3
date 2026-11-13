# linux-zflip3

Mainline-based Linux on the Samsung Galaxy Z Flip3 5G (`SM-F711N`, codename `b2q`), with the
install tools and notes needed to run Arch Linux on it. Port by Noa Himesaka. Not affiliated with
Samsung.

**Status: daily-usable bring-up.** Arch Linux Ports with Plasma Mobile runs from UFS with
display, touch, Wi-Fi, Bluetooth, GPU, charging, speakers, earpiece, microphone, cellular data,
SMS, MMS and VoLTE calls (including waking from suspend on incoming messages and calls),
USB host/OTG, hardware video decode (H.264, HEVC and VP9; see
[`VIDEO-DECODE.md`](VIDEO-DECODE.md)), the cover display and its touchscreen, camera
flash/torch LED, the SSC's accelerometer, gyroscope, magnetometer, compass and ambient light
sensors, the SX9360 grip sensor that also provides proximity, GNSS through ModemManager's
QMI LOC, the fingerprint sensor (Samsung's own TrustZone app, enroll in Settings, unlock at
the lock screen; [`FINGERPRINT.md`](FINGERPRINT.md)), NFC, and all three cameras (raw
capture through CAMSS, pictures through libcamera's software ISP;
[`CAMERA.md`](CAMERA.md)). Not yet: hardware video encode, autofocus and OIS, wireless
charging, the hinge angle beyond open/closed, and a tuned thermal policy.
The roadmap and the reasoning behind each step live on the `docs` branch
([`docs/plan.md`](https://github.com/noas-slopware/linux-zflip3/blob/docs/docs/plan.md)).

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
| Cellular | SM8350 modem (mpss) over QRTR/IPA. LG U+ never ran 3G, so calls and SMS are IMS only: VoLTE and SMS over IMS through our own userspace IMS stack, [IMSroha](https://github.com/noas-slopware/imsroha) |
| Boot chain | Stock Samsung ABL, unlockable. Non-A/B, 96 MB `boot` **and** `recovery`, Android boot header v2 with appended DTB |

## What works

"Verified" means seen working on the unit. Kernel 7.3.1 build #7 from the patch series
0001-0081 (0043 held), 2026-11-10.

| Subsystem | Status |
|---|---|
| Boot (ABL → U-Boot → mainline kernel) | verified |
| USB device: gadget console, networking | verified |
| UFS, rootfs (Arch Linux Ports aarch64) | verified |
| Wi-Fi, Bluetooth, GPU (a660/freedreno) | verified |
| Main display, touchscreen | verified |
| Fold sensor: closing suspends, opening wakes | verified |
| Charging, dual cells, fuel gauge | verified |
| Speakers, earpiece, microphones | verified |
| Cellular data (LG U+ LTE, IPv6 + CLAT) | verified |
| IMS registration (ISIM AKA) | verified |
| SMS send and receive, received while ModemManager or the phone was down | verified |
| MMS send and receive (Spacebar) | verified |
| VoLTE calls in and out, to and from other networks, AMR-WB / AMR-NB | verified |
| DTMF in calls | verified (ModemManager 1.24.2-11 with IMSroha's `modemmanager/0004-*`) |
| Incoming call or SMS waking the phone from suspend | verified |
| USB host/OTG (Type-C peripherals: YubiKey, USB-C audio/DAC, flash drives) | verified |
| Hardware video decode (qcom-iris via qcom-va-driver) | verified: VP9 and H.264 in Firefox 159; H.264 with B-frames and HEVC decode bit-exact against software ([`VIDEO-DECODE.md`](VIDEO-DECODE.md)) |
| Camera flash and torch LED (S2MPB02) | verified, with the S2MPB02 MFD/regulator rework and the blink-free torch refresh (`patches/linux/0026-*` to `0031-*`) |
| SSC sensors: accelerometer, gyroscope, magnetometer, compass, ambient light | verified (data via `ssccli`; `iio-sensor-proxy` reports them) |
| Grip sensor (Semtech SX9360, IIO proximity) | verified (raw channels; its main electrode is the phone's proximity sensor) |
| GNSS | verified through ModemManager's QMI LOC (`gps-raw`, `gps-nmea`; no fix indoors, no `/dev/gnss`) |
| Cover display | working: 512x260 strip; `kita` leases the non-desktop connector, sleeps by default and wakes on notification/call/SMS/power key; the main panel is DPMS Off while folded and only the cover is active; the call banner clears on hangup |
| Fingerprint sensor (power button) | verified: Samsung's securefp TrustZone app through `/dev/qsee-app`, libfprint `samsung_securefp`, fprintd; `claire` serves the secure processor's storage and sets up the key that seals templates; enroll in Settings, unlock at the lock screen ([`FINGERPRINT.md`](FINGERPRINT.md)) |
| NFC (NXP SN100U) | verified: `nxp-nci` at i2c15 0x2b, neard reads tags (a YubiKey's NDEF URI) |
| Cameras: rear wide (IMX563), ultrawide (IMX258), front (IMX374) | verified: raw capture at full resolution and 30 fps on all three (the wide one over C-PHY), colour bars exact; pictures through libcamera 0.7.2's software ISP with auto exposure ([`CAMERA.md`](CAMERA.md)) |
| Cover touchscreen (Zinitix ZTW522) | verified: vendor protocol driver/DT in `patches/linux/0038-*`, `0039-*`; `kita` grabs the evdev and dismisses tapped cards while the cover is lit; a tap never wakes it, a swipe does; udev keeps libinput off it |

## Not working yet

"Not started" means there is no driver, no DT node, or no userspace integration in this tree,
not that the hardware is broken on this unit.

| Subsystem | State |
|---|---|
| 5G NR | the modem reports the capability; data and voice have only been verified on LTE |
| Cameras: autofocus, OIS, calibration | the wide camera's lens actuator (CCI1 0x18) and OIS MCU (QUP SE2) have no driver, so it is fixed-focus; no lens-shading/AWB calibration from the module EEPROMs and no libcamera tuning files; the hardware ISP (IFE pixel path) is not pursued |
| Hardware video encode | not registered on SM8350: any encode resets the SoC on the first input frame, so `/dev/video1` stays skipped (0043 held) |
| Wireless charging and reverse wireless charging | 5 W (Qi BPP) verified 2026-11-11 through the IDT P9320 receiver (0084, 0085) and the MAX77705 wireless input (0083), no Samsung fast wireless (10 V) yet; reverse wireless not ported |
| Hinge angle | only open/closed via `SW_LID`, no angle sensor |
| Idle power, thermal limits, charge curves | not tuned; QC 2.0 is in (0082) but not yet seen on a QC charger (wired tops out at 15 W like stock: USB PD 9 V fixed PDO or AFC; stock never asks for a PPS APDO, it has no direct charger) |

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

- ~~Motion and environment sensors~~: done (SSC on the SLPI, plus the SX9360 grip sensor).
  Auto-rotate through Plasma is confirmed.
- ~~Fingerprint, NFC, H.264 B-frames and HEVC decode, the three cameras~~: done.
- Hardware video encode: any encode resets the SoC on the first input frame (0043 held).
- Cameras: the wide camera's autofocus actuator (CCI1 0x18) and OIS (QUP SE2), calibration
  from the module EEPROMs, libcamera tuning files, and flash tied into capture.
- Wireless charging: see it work on a pad, then Samsung fast wireless (10 V) and reverse
  wireless; a thermal policy.
- Idle power, round two: system suspend once the temporary sleep inhibitor goes, modem and
  Wi-Fi power save, RPMh rails nothing votes for.

### The packaged system

Everything the phone runs is packaged on the `arch` branch, with the build tools: the kernel
(`linux-zflip3`, Arch's `linux` PKGBUILD on this branch's series and config), the firmware
(`firmware-zflip3`, extracted at build time from Samsung's stock F711NKSSFKZH5 tars by `tools/`
here, so none of Samsung's files are in git), the phone's configuration (`zflip3-device`:
`zflip3-system`, `-boot`, `-audio`, `-cellular`, `-plasma`, from `userspace/rootfs`), our
daemons, IMSroha with its ModemManager and Spacebar forks, the forks under `patches/` and the
AUR packages Arch Linux Ports lacks. `tools/mkimage-zflip3.sh` there makes the generic root file
system (no personal settings; `verify-zflip3-image.sh` refuses one that has any), which
`userspace/installer/install-rootfs.sh` unpacks. `zflip3-boot` packs the kernel, a mkinitcpio
initramfs and the device tree into the boot image and writes it to `recovery` itself, read back
and compared, on every kernel update.

Not packaged yet:

- hardware video decode: `qcom-va-driver 1.1.1` from `github.com/nyanmisaka/libva-v4l2-qcom`,
  built with `tools/build-qcom-va-driver.sh` after the local patch (`VIDEO-DECODE.md`),
- mobile-config-firefox 5.5.0 with the four Fenix patches from linux-hiby-rs6,
- the CS35L41 module with the 15 ms mailbox, once it is final.

### Hardware variants

The port was brought up on one unit (board revision 8, ultrawide IMX258, main panel S6E3HAD
rev D). What other Korean SM-F711N units can differ in, from Samsung's stock kernel, device
tree overlays and vendor files:

- **Board revision.** Stock's dtbo has one entry per revision range; the non-US entries for
  revision 7 and up (7, 8-11, 12 and later) are identical but for the revision fields, so every
  retail unit gets the device tree this port was written from. Revisions 5 and 6 (pre-production)
  differ in battery and fuel gauge data and the fingerprint orientation.
- **Main panel revision** (A to D, from the third ID byte): `0136` reads it and sends that
  revision's display-on sequence, with VBIAS and VAINT for A to C, and A/B's or C/D's 96 Hz
  gamma offsets, as stock does. Only D has been tried.
- **Rear ultrawide sensor**: stock ships a module for a Samsung S5K3L6 next to the IMX258 and
  identifies the fitted one by chip ID. `0137` adds an S5K3L6 driver from stock's settings; the
  device tree still describes only the IMX258, because CAMSS waits for every sensor in its graph
  before it registers any camera, so a node for an absent sensor would take all three cameras
  away. Picking the node at boot (both nodes `fail-needs-probe`, a probe of the chip IDs with
  the slot powered as stock powers it, CAMSS skipping the node that lost) is the next step and
  needs a boot on the phone to confirm the IMX258 path still comes up.
- **Cover touch firmware**: stock reflashes the ZTW522 when its firmware is older than
  `/vendor/firmware/ztw522_b2.bin` (minor 0x23, register data 0x14) and never downgrades, so a
  unit that last ran stock One UI 7 already runs that firmware; the port does not flash it.
- **Wide camera**: stock has a DV0/DV1 module description without autofocus actuator or OIS
  next to the retail DV2 one; DV0/DV1 look like development modules.
- Stock's dtbo also lists other main and cover panels (S6E3HA9, S6E3FAC, S6E36W3 AMB114EU09)
  that its kernel builds drivers for; whether any retail F711N has one is not known.

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
| `arch` | the PKGBUILDs of every package the phone runs, and the tools that build them and the image |
| `docs` | write-ups: plan, boot chain, panel, storage, cellular, evidence policy |
| `firmware` | a README; `firmware-zflip3` (`arch`) extracts the files from the stock firmware instead |

```
patches/linux/           numbered series against sources.lock's LINUX_VERSION
patches/u-boot/          SM8350 and b2q support for U-Boot
patches/<package>/       patches for other projects' packages (libcamera, libfprint, fprintd,
                         gtk4, kscreenlocker, plasma-mobile, wireplumber, ...); PKGBUILDs on arch
tools/                   host-side: extract firmware, build, pack, flash and install images
userspace/installer/     bring-up initramfs and installer
userspace/rootfs/        the phone's configuration (zflip3-device on arch)
userspace/claire/        secure-world services the fingerprint TA needs
userspace/mihari/        stock's skin temperature estimate and SIOP limits
userspace/kita/          the cover display
VIDEO-DECODE.md          the hardware decode stack, measurements and caveats
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
`tools/` and `userspace/` is MIT; `patches/<package>/` follow their project's license.
