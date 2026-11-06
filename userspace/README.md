# Userspace

Files that run on the phone, as opposed to `tools/` which runs on the host.

| path | what |
|---|---|
| `installer/init` | PID 1 of the bring-up initramfs (USB console on `ttyGS0`, pstore dump) |
| `installer/install-rootfs.sh` | M3.5: format `super`/`userdata` and unpack the Arch rootfs |

`installer/init` is copied into the initramfs by `tools/build-initramfs.sh`; it is not
duplicated in the build.

The same `recovery` image that runs the installer stays flashed afterwards as the rescue
environment: it can fsck, reinstall and dump partitions over USB, and it is the reason a
broken `boot` partition is not a brick.

Later, once the display works, this directory is where the mobile shell lives (sway plus
waybar for bring-up, `plasma-mobile` if a phone-shaped UI is wanted).
