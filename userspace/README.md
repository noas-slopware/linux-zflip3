# Userspace

Files that run on the phone, as opposed to `tools/` which runs on the host.

| path | what |
|---|---|
| `installer/init` | PID 1 of the bring-up initramfs (USB console on `ttyGS0`, pstore dump) |
| `installer/install-rootfs.sh` | M3.5: format `super`/`userdata` and unpack the Arch rootfs |
| `imsd/` | `b2q-imsd`, userspace IMS daemon (SIP over the modem's IMS PDN); unit, packaging and the Phase 1.5 ModemManager design, see `imsd/README.md` |
| `rootfs/` | overlay copied over `/` by `tools/build-rootfs.sh`: units, udev rules, NetworkManager, UCM, cover display |
| `rootfs-packages.txt` | the phone's explicitly installed repo packages, installed by `tools/build-rootfs.sh` |
| `b2q-cover/` | `b2q-coverd`, the cover display (leased DRM connector, clock, notifications, calls) |

Packages built natively on the phone (`makepkg` as `<user>`) and given to
`tools/build-rootfs.sh --packages`; each PKGBUILD starts from Arch's or the AUR's:

| path | version | why |
|---|---|---|
| `b2q-spud/` | 0.1.0-6 | fingerprint glue for the securefp TA |
| `callaudiod/` | 0.1.99-4 | switches the call profile for the speaker button |
| `hexagonrpcd/` | 0.5.0-1 | file server for the sensor hub (SLPI) |
| `iio-sensor-proxy/` | 3.9-2 | SSC sensors |
| `imsd/` | 0.1.0-20 | IMS: `b2q-imsd`, `b2q-ims-bearer`, `b2q-ims-audio`, `b2q-vss-manager` |
| `kscreenlocker/` | 6.8.2-2 | keeps the fingerprint reader armed at the lock screen |
| `libcamera/` | 0.7.2-8 | IMX374/IMX563 helpers, soft ISP autofocus for the wide camera |
| `libfprint/` | 1.94.100-5 | `samsung_securefp` driver |
| `neard/` | 0.20-1 | NFC |
| `plasma-camera/` | 26.08.3-2 | cameras named by location |
| `plasma-mobile/` | 6.8.2-3 | volume popup without a default sink, quick settings fix |
| `rmtfs/` | 1.3-1 | modem remote filesystem (the AUR has 1.2) |
| `spacebar/` | 6.3.4-4 | LG U+ MMS send |
| `tqftpserv/` | 1.3.r4.geb4b9a0-1 | modem TFTP server with populate-readwrite (the AUR has 1.2) |
| `wireplumber/` | 0.5.18-2 | keeps the call profile picked during a call |

ModemManager and its patches are in `patches/modemmanager/`.

`installer/init` is copied into the initramfs by `tools/build-initramfs.sh`; it is not
duplicated in the build.

The same `recovery` image that runs the installer stays flashed afterwards as the rescue
environment: it can fsck, reinstall and dump partitions over USB, and it is the reason a
broken `boot` partition is not a brick.
