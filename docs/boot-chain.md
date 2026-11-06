# Boot chain

```
power on
  -> XBL / ABL (Samsung, signed, unmodifiable)
       |-- boot reason "recovery" -> recovery partition
       `-- otherwise              -> boot partition
  -> our kernel + initramfs + dtb
```

No slot logic: this is a non-A/B device (`AB_OTA_UPDATER := false` in the LineageOS device
tree), and Samsung ignores the AOSP slot and BCB interfaces anyway. `boot` and `recovery`
are two independent 96 MB (`100663296` byte) partitions, which is why `recovery` makes a
good second kernel slot.

## What the images have to look like

This firmware uses **boot header v3 and keeps the device tree in `vendor_boot`**. Measured
from the stock AP tar:

| image | header | contents |
|---|---|---|
| `boot.img` | v3 | kernel, ramdisk, command line, **no dtb** |
| `vendor_boot.img` | v3 | **dtb (1.4 MB)**, vendor ramdisk, `board = SRPUC29A015` |
| `dtbo.img` | - | 7 overlays, 24 MiB, every panel definition lives here |

So M1 is two images, not one:

```sh
tools/bootimg.sh --kernel Image --ramdisk initramfs.cpio.gz --out boot.img
tools/bootimg.sh --vendor --dtb b2q.dtb --out vendor_boot.img
tools/flash.sh --image boot.img --partition boot
tools/flash.sh --image vendor_boot.img --partition vendor_boot
```

`boot.img` and `recovery.img` get the ASCII trailer `SEANDROIDENFORCE`; `vendor_boot` does
not, matching what the stock images and LineageOS do.

The board string is **`SRPUC29A015`** on this build, not the `SRPUC03A002` the old
LineageOS tree hardcodes. `tools/bootimg.sh` takes it from the stock image's own
`mkbootimg` arguments rather than from a constant.

The dtb in `vendor_boot` is only the platform: it has no panel nodes. Panel variants live
in the dtbo overlays and the phone picks one at runtime from the panel ID, so our board
DTS has to do the same, or the panel driver has to be told which panel it is.

## Flashing

Use `odin4` (Thor protocol). Heimdall is unreliable on SM8350-class Samsungs. Odin matches
partitions by the file name *inside* the tar, so `tools/flash.sh` writes a tar whose single
member is `recovery.img` or `boot.img`.

Download mode: `adb reboot download`, or hold Power+Volume Down and plug in USB.

## Failure signatures

| Symptom | Meaning |
|---|---|
| Resets to the Samsung logo immediately | ABL rejected the image: board string, header version, or the trailer |
| "SECURE CHECK FAIL" or a verity error | flash `vbmeta_disabled.img` (`avbtool make_vbmeta_image --flags 2`); AVB is still enforcing |
| "Only official released binaries are allowed" | KG/RMM Prenormal: the device is not really unlocked yet |
| Screen stays dark and the phone does not reboot | the kernel took over and died early. Progress: read pstore on the next boot |
| Boots, no console | `g_serial` missing from the config, or the USB controller did not bind |
| Repeated failures then "unbootable" | Samsung's bootloop protection. Flash the stock AP tar; nothing is lost |

## Debugging without a UART

There is no accessible serial port on this board. In order of usefulness:

1. **USB gadget console.** `CONFIG_USB_G_SERIAL=y` makes `/dev/ttyGS0` appear with no
   userspace work; `userspace/installer/init` hands the shell to it.
2. **pstore/ramoops.** A reserved-memory carveout that survives a panic, dumped by the next
   boot's init. This is the only way to see a panic before USB comes up.
3. **Boot outcome.** Does the screen blank, does the phone stay alive on the bus, does adb
   disappear. Crude, but it distinguishes "ABL rejected it" from "kernel died" in seconds.
