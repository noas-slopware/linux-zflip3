# Userspace

Files that run on the phone, as opposed to `tools/` which runs on the host.

| path | what |
|---|---|
| `installer/init` | PID 1 of the bring-up initramfs (USB console on `ttyGS0`, pstore dump) |
| `installer/install-rootfs.sh` | M3.5: format `super`/`userdata` and unpack the Arch rootfs |
| `rootfs/` | the phone's configuration: units, udev rules, NetworkManager, UCM, IMSroha's drop-in (`zflip3-device` on `arch`; `tools/build-rootfs.sh` copies it over `/`) |
| `kita/` | `kita`, the cover display (leased DRM connector, clock, notifications, calls) |

Our own programs are here: `claire/` (fingerprint secure-world glue), `mihari/` (stock's skin
temperature estimate and SIOP limits) and `kita/`; `rootfs/` is the phone's configuration.
They are packaged on the `arch` branch (`claire`, `mihari`, `kita`, the `zflip3-device` split
packages from `rootfs/`), which builds each from a tarball of this branch. The patches for
other projects' packages (libcamera, libfprint, fprintd, gtk4, ...) are under `patches/`,
one directory per package; their PKGBUILDs are on `arch`, each based on Arch's or the AUR's.

IMS (VoLTE, SMS over IMS) is [IMSroha](https://github.com/noas-slopware/imsroha), split out of
this repository's `userspace/imsd/` on 2026-11-11; `arch` builds it, and the ModemManager and
Spacebar forks it needs, from that repository's tarball. This phone's side of it is
`rootfs/usr/share/imsroha/imsroha.conf.d/50-zflip3.conf` and the `imsroha-vss-samsung.service.d/b2q.conf` drop-in.

`installer/init` is copied into the initramfs by `tools/build-initramfs.sh`; it is not
duplicated in the build.

The same `recovery` image that runs the installer stays flashed afterwards as the rescue
environment: it can fsck, reinstall and dump partitions over USB, and it is the reason a
broken `boot` partition is not a brick.
