# Repository instructions

## USB access: `usbip-helper`

This VM does not have the phone plugged in directly. USB devices live on
`yuifunami@192.168.0.6` and are attached over USB/IP. **Every time the phone
re-enumerates** (reboot, unplug, mode switch into download mode, or after a flash), it
disappears from this VM and must be re-attached:

```sh
usbip-helper list            # local devices on 192.168.0.6, with busids
usbip-helper bind  <busid>   # export on the host, then attach here
usbip-helper unbind <busid>  # detach
```

`usbip-helper` is a thin Python wrapper: `list` runs `ssh yuifunami@192.168.0.6 sudo usbip
list -l`, `bind` runs `usbip bind` there and then `sudo usbip attach -r 192.168.0.6 -b
<busid>` locally, `unbind` runs `usbip unbind` there. It only supports those three
subcommands.

**Never reuse a busid.** It changes across re-enumeration, so always `list` first and check
the vendor/product ID before binding:

| id | what |
|---|---|
| `04e8:6860`, `04e8:6863`, `04e8:6866` | the phone (MTP/ADB) |
| `04e8:685d` | the phone in download mode |
| `04e8:3321` | **the Samsung M2020 printer on this desk, not the phone** |

`04e8:3321` reports as "M2020 Series" with a Printer-class interface. It is the only
`04e8` device that was visible on 192.168.0.6 at the start of this project; binding it by
mistake attached the printer to this VM. Check `lsusb -d <id> -v | grep bInterfaceClass`
before assuming a `04e8` device is the phone.

After attaching, `lsusb` should show the device and `adb devices` should list it. If
`adb devices` is empty while `lsusb` shows a device, it is the wrong device or the phone is
in charging-only USB mode.

## The device

SM-F711N, CSC `LUC`/OKR, One UI 7 (Android 15). USB debugging on, OEM unlocking enabled.
Unlocking the bootloader itself (and the wipe it forces) has not happened yet.

Do not flash anything without `B2Q_UNLOCKED=1`, and never without the stock 4-file firmware
saved first.

## USB/IP does not work for this phone in Android

The phone resets its USB gadget as soon as `usbip bind` detaches its interfaces. On the host:

```
usbip-host 7-3.2: stub up
usbip-host 7-3.2: USB disconnect, device number 44
usb 7-3.2: new high-speed USB device number 45 ...
```

After that `7-3.2/driver` is `usb`, not `usbip-host`, usbipd has no export, and `usbip attach`
fails with "Device not found" no matter how fresh the busid is. It is not the cable and not a
stale busid, so re-listing and retrying does not help.

- **Android / adb:** use wireless debugging on the LAN instead. This VM is 192.168.0.154/24,
  the phone and the desktop are on the same subnet: `adb pair <ip>:<port> <code>`, then
  `adb connect <ip>:5555`.
- **Download mode (`04e8:685d`):** a single bulk interface that does not churn, so usbip attach
  is worth trying there when flashing. If it still fails, run `odin4` on the desktop.
