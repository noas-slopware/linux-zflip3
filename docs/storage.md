# Storage

## What the phone has

- 128 or 256 GB UFS, no microSD slot. Everything lives on the internal chip.
- Non-A/B, dynamic partitions: `super` is 12 GB and holds Android's
  `system`/`vendor`/`product`/`odm` as logical partitions. `userdata` is the rest, f2fs.
- Partitions that must never be written: `persist` (Wi-Fi/BT MACs, calibration), `efs`
  (IMEI and RF data), `param`, `modemst1`/`modemst2`, and anything named like a bootloader.

## Layout for Arch

No GPT surgery. The two big partitions are reformatted in place:

| partition | label | mount | size |
|---|---|---|---|
| `super` | `b2q-root` | `/` | 12 GB |
| `userdata` | `b2q-home` | `/home` | rest of the disk |

`super` is big enough for a full Arch install with a desktop and a toolchain. `userdata`
gets the rest, and is where `pacman`'s cache, containers and anything large belong.

`fstab` is written by `tools/build-rootfs.sh` as `/etc/fstab.b2q` and renamed into place by
the installer, so labels rather than device paths are used. There is no swap partition;
use `zram` (the SoC has 8 GB and the storage is better spent on space).

## Why not shrink `userdata` instead

Android formats it f2fs, which cannot be shrunk offline. Keeping Android and sharing the
disk would mean a loop-mounted image file inside `/data`, which is a worse default for a
device that is meant to be dedicated; it is only worth it for the M1–M3 bring-up window,
where Android is still in `boot` and the rootfs can live in a file until M3.5.

## Install flow

1. Boot the rescue image (`recovery`).
2. Bring up USB networking, or plug a USB-C stick with the rootfs tar into an OTG adapter.
3. `userspace/installer/install-rootfs.sh --rootfs … --boot boot.img --yes-wipe`
4. Flash `boot.img` to `boot`, reboot.

The installer is dry-run unless `--yes-wipe` is passed, and it prints the partition and
label it is about to destroy.
