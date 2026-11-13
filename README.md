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

### For the rootfs rebuild

Done by hand on the phone and not yet in `tools/build-rootfs.sh`; it goes in once
everything, cellular included, works:

- packages beyond `ROOTFS_PACKAGES`: `mesa mesa-utils plasma-mobile plasma-login-manager
  plasma-settings qmlkonsole bluedevil kscreen firefox feedbackd evtest i2c-tools plasma-dialer geoclue
  polkit-kde-agent` (without it nothing can answer fprintd's `auth_self_keep` enroll prompt, and Settings gets "Not Authorized"),
  (plus the Adreno zap shader),
- the cellular stack built on the phone: `imsroha` from
  [IMSroha](https://github.com/noas-slopware/imsroha)'s `packaging/`, ModemManager 1.24.2 from its
  `modemmanager/` (0001, 0003-0007), Spacebar 6.3.4 from its `spacebar/` (MMS fixes,
  RCS chat and file transfer), and `opencore-amr` plus `vo-amrwbenc` for the call codecs,
- hardware video decode (not a pacman package): `qcom-va-driver 1.1.1` from
  `github.com/nyanmisaka/libva-v4l2-qcom` at `~/src/qcom-va-driver`, built with
  `tools/build-qcom-va-driver.sh` after the local patch; it installs
  `/usr/lib/dri/qcom_drv_video.so` plus the `msm`/`v4l2` aliases. See `VIDEO-DECODE.md`,
- the audio bits: `tools/extract-amp-firmware.sh` output in `/usr/lib/firmware/cirrus/`,
  the UCM files under `userspace/rootfs/usr/share/alsa/ucm2/`, the WirePlumber drop-in
  under `userspace/rootfs/etc/wireplumber/`, and the CS35L41 module once the 15 ms
  mailbox build is final,
- IMSroha's device settings, `/etc/imsroha/imsroha.conf`, from `--overlay` for now
  (its units create `/var/lib/imsroha/inbox` and `/run/imsroha`; an inbox left in
  `/var/lib/b2q-imsd` is moved over once),
- the sensors: `tools/extract-qcom-firmware.sh ... slpi` and
  `tools/extract-sensor-files.sh` output (the DSP skels, sensor configs and
  `sns_reg.conf` under `/usr/share/qcom/sm8350/Samsung/b2q/`), `hexagonrpcd` from
  `userspace/hexagonrpcd`, the patched `iio-sensor-proxy` from
  `userspace/iio-sensor-proxy` (`-Dssc-support=enabled` and the claim race patch),
  and `renge.service` plus the `81-b2q-sensors.rules` udev rule from
  `userspace/rootfs/`,
- the NFC userspace stack: `neard` from `userspace/neard` (not in the ports repos),
  which also provides `nfctool` for `/dev/nfc0`,
- the cover daemon: the `kita` package from `userspace/kita/`, which leases DSI-2 from
  KWin, drives the panel with Cairo/Pango and controls its backlight (it brings its
  autostart file and udev rules),
- the personal settings, from `tools/build-rootfs.sh --overlay`: hostname, the carrier's
  data connection and Spacebar MMSC, the user and its autologin (`LockOnStart` is in
  `userspace/rootfs/etc/xdg/`, so the first screen is Plasma Mobile's lock screen),
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
patches/qcom-va-driver/  local patch for the qcom-va-driver V4L2 backend
patches/plasma-keyboard/ Korean composition, content types
tools/                   host-side: extract firmware, build, pack, flash and install images
VIDEO-DECODE.md          the hardware decode stack, measurements and caveats
userspace/installer/     bring-up initramfs and installer
userspace/rootfs/        files the rootfs carries on top of the distribution
userspace/hexagonrpcd/   FastRPC filesystem daemon for the sensor hub
userspace/iio-sensor-proxy/ iio-sensor-proxy with the SSC claim-race fix
userspace/neard/         Linux NFC daemon and nfctool for the NCI stack
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
