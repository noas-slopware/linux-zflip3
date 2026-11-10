# Tools

Host-side scripts. Every one takes `--help`; none of them touches the phone unless you
give it the device.

| script | stage | what it does |
|---|---|---|
| `fetch-firmware.sh` | M0 | download the stock firmware through Samsung's FUS (samloader-rs) |
| `extract-firmware.sh` | M0 | AP tar → `boot.img`, `dtbo.img`, decompiled DTS, stock `mkbootimg` args |
| `evidence.sh` | M0 | read-only dump of props, cmdline, partitions, battery into `evidence/device/` |
| `fetch-kernel.sh` | M1 | download and verify the pinned mainline, optionally apply `patches/linux/` |
| `build-kernel.sh` | M1 | configure and build `Image` + the b2q dtb (encodes the TYPEC/PHY tristate traps) |
| `mkimages.sh` | M1 | pack U-Boot `boot.img`, Linux `linux.img` for recovery, and an empty `dtbo.img` |
| `build-u-boot.sh` | M1 | build U-Boot from the pinned tag plus `patches/u-boot/` |
| `extract-qcom-firmware.sh` | M2 | Samsung-signed SoC firmware (GPU zap shader, IPA, SLPI, VPU) from the BL tar, as `.mbn` |
| `extract-sensor-files.sh` | M4 | sensor hub configs, registry skel and DSP skels from the vendor image, for hexagonrpcd |
| `pil-squash.py` | M2 | join a split `.mdt`/`.bNN` firmware image into one `.mbn` |
| `install-images.sh` | M2 | write boot/recovery images from the running phone over ssh |
| `build-initramfs.sh` | M1 | static busybox initramfs with the USB console init |
| `bootimg.sh` | M1 | pack kernel + initramfs + dtb with the stock header, append `SEANDROIDENFORCE` |
| `flash.sh` | M1 | flash one partition with heimdall on the host the phone is plugged into |
| `phone-usb.sh` | all | find the phone among the USB/IP devices and attach it |
| `build-rootfs.sh` | M3 | Arch Linux Ports aarch64 rootfs from the drzee.net bootstrap tarball |

## Conventions

- `lib.sh` is sourced, not executed: `die`, `warn`, `log`, `need`, `require_unlocked`.
- Anything that writes to the phone refuses to run without `B2Q_UNLOCKED=1`, and prints the
  checklist instead.
- `extract-firmware.sh` writes the stock boot header to `out/boot/mkbootimg_args`;
  `bootimg.sh` reuses it so the board string and offsets are never guessed.
- Everything large goes to `.cache/`, `out/` or `evidence/raw/`, all gitignored.
