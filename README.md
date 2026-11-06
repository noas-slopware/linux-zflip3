# firmware

Vendor blobs the phone needs at runtime, pulled from the stock firmware **before** the
Android partitions are wiped. Everything here is Samsung's, Qualcomm's or QCA's; no license
is granted, and the branch exists so the port has a reproducible source for them rather
than "copy it off your phone".

## Where each one comes from

| file | source on the device | needed by |
|---|---|---|
| `adsp.mbn`, `adspr.jsn`, `adspua.jsn` | `/vendor/firmware_mnt/image/` | ADSP remoteproc (audio, sensors) |
| `cdsp.mbn`, `cdspr.jsn` | same | CDSP remoteproc (compute) |
| `modem.mbn`, `mba.mbn`, `modemr.jsn` | same | modem (out of scope for now) |
| `ipa_fws.mbn` | same | IPA (modem data path) |
| `a660_zap.mbn` | same | Adreno 660 zap shader |
| `bdwlan.b*`, `board-2.bin`, `m3.bin`, `amss.bin` | same, WCN6855 set | ath11k |

## How to collect them

The rescue initramfs can dump `vendor` (or the extracted `super`) over USB mass storage, so
this does not need Android root. From the host:

```sh
tools/extract-firmware.sh --with-super ~/fw/AP_*.tar.md5
lpunpack --partition=vendor evidence/raw/super.img out/vendor
cp out/vendor/etc/firmware/* .
```

## What must never be committed here

- `efs`, `persist`, `param`, `modemst1`, `modemst2`: IMEI, RF calibration, Wi-Fi and
  Bluetooth MAC addresses. They are device-specific and personal. Keep them offline.
- Serial numbers, `sec` partition dumps, anything from `/data`.

If a blob turns out to carry one of those (the modem images can), strip it or leave the file
out and document what the port needs instead.
