# The boot gate: KG and VaultKeeper

The bootloader on this phone is unlocked (`OEM LOCK: OFF (U)`, `ro.boot.flash.locked = 0`,
`verifiedbootstate = orange`) and still refuses to run images it did not sign. That is not a
contradiction; it is a second gate that the unlock does not touch.

## What is established on this unit

- Flashing always succeeds. `heimdall flash` reports `BOOT upload successful`,
  `VENDOR_BOOT upload successful`, and the partitions really contain the bytes.
- The refusal happens at boot: Galaxy logo, then fallback to download mode.
- The refusal is content-independent. Stock `boot` + `vendor_boot` + `dtbo` boots Android.
  Our `boot` + `vendor_boot`, packed with the stock header fields, the stock board string
  and the same flasher, is refused. A kernel with a valid header whose entry is an infinite
  loop is also refused, which proves ABL never jumps to it.
- The state that changes the outcome is `knox.kg.state`. `Completed` boots; `Checking` does
  not. `tools/gate.sh` reads it.

## Why: VaultKeeper

The mechanism is described by [Kragujević](https://milankragujevic.com/how-to-avoid-rmm-state-prenormal-when-unlocking-samsung-phones):

> the bootloader is unlocked, but a new service on the device, the VaultKeeper, does not
> allow flashing… If you attempt to flash a custom binary while the bootloader is unlocked
> but VaultKeeper is not released, your device will be switched to "RMM STATE: Prenormal",
> which will prevent any flashing of any binaries for a week or more.

So VaultKeeper is a release flag, and flashing before it releases is what arms the block.
The download screen can show `OEM LOCK: OFF (U)` the whole time, because the two gates are
independent.

## Release procedure

1. Boot Android, online, finish setup.
2. Open Developer options and confirm the OEM unlocking row **exists, is on, and is greyed
   out**. Opening that screen is what makes VaultKeeper verify the device.
3. Reboot into Android once more.
4. `adb reboot download` (from Android, not the key combo, not the fallback screen).

## What the time actually is

The same source is explicit that the duration is not documented — "you have to wait the
defined time, which is not written anywhere", so the practical approach is to check daily
rather than trust the often-quoted 168 hours. Reports range from hours to over a week, and
[one XDA post](https://xdaforums.com/t/samsung-kg-state-completed-meaning.4668150/) says
`Checking` blocks while [the /e/ community](https://community.e.foundation/t/root-lost-after-ota-update-on-galaxy-s20-kg-state-checking/74477)
reports it does not. This unit is in the blocking group.

## What does not exist

No public exploit for this boot chain: no SM8350 firehose loader
([edl#518](https://github.com/bkerler/edl/issues/518)), the Zygote unlock needs a May 2024
patch or older, the 2026 GBL trick needs Android 16 and its `efisp` handoff, and the
Qualcomm boot-partition CVE-2026-24088 requires root before it is useful and does not list
this chipset. There is no shortcut, only the flag.
