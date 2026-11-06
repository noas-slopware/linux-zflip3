# Plan

Goal: Arch Linux on the Samsung Galaxy Z Flip3 5G (`SM-F711N`, `b2q`), with the main
display and touchscreen working, no cellular. It is a toy and a spare device; the payoff
is a foldable running mainline Linux, which nothing has done yet, plus an upstreamable
DTS, panel driver and touch driver.

Non-goals: telephony, cameras, DeX-style output, dual-booting Android.

## Decisions

**D1: no U-Boot.** Samsung's ABL already boots an Android boot image, and the bootloader is
unlockable on this model. U-Boot would buy extlinux and a charging screen, and cost a
port of its own. The kernel goes straight into `boot.img`. (The HiBy RS6 port needed
U-Boot only because its ABL was locked and could only chainload.)

**D2: the `recovery` partition is the bring-up slot.** Non-A/B layout, two independent
96 MB images, and `adb reboot recovery` selects one without a key combo. Every experiment
in M1–M3 runs from `recovery` while Android stays in `boot`. After the wipe, `recovery`
keeps the rescue installer permanently: a broken `boot` partition is then an inconvenience,
not a brick.

**D3: the wipe happens late.** The device is meant to be dedicated, but the wipe is a
M3.5 action, not a M0 one. Until Arch boots and USB networking works, Android is the only
reliable charger and the only rollback.

**D4: no GPT surgery.** `super` (12 GB) becomes `/`, `userdata` becomes `/home`, both
reformatted in place. Repartitioning a Samsung GPT for a toy is a bad trade.

**D5: Arch Linux Ports aarch64.** The drzee.net ARMv8.2+ repos, not the ARMv8 baseline of
archlinuxarm.org: the Kryo 680 implements the v8.2 instructions those packages are built
for. Note that this is not an official Arch port, so the packages are community-built.

**D6: patches, not a vendored kernel.** `patches/linux/` against the pinned
`LINUX_VERSION`, applied by `tools/fetch-kernel.sh`. Same shape as the RS6 port, and it is
what an upstream submission needs anyway.

**D7: the board DTS is generated from the stock firmware, not written by hand.** The
`lahaina` base DTB and the `b2q` overlays that ship on the phone describe every supply,
GPIO and panel timing. `tools/extract-firmware.sh` pulls them out and decompiles them;
the first DTS is assembled from that, with each value traceable to a node.

## Milestones

| # | Result | Acceptance |
|---|---|---|
| M0 | Unlocked, backed up, firmware archived | `OEM LOCK: OFF`, `KG State: Normal`, EFS/persist dumps in `evidence/`, stock AP tar kept, `boot/mkbootimg_args` extracted |
| M1 | Our image boots from `recovery` | 5/5 clean boots, serial console or pstore output, no bounce back to the Samsung logo |
| M2 | It is a computer | `ssh` over USB networking, UFS mounted, Wi-Fi associated, `glxinfo`/`kmscube` on the GPU |
| M3 | Arch | `pacman -Syu` over that ssh, `linux-b2q` installed, reboot still works |
| M3.5 | Dedicated | Android gone, root and home on labels, charger behaviour known |
| M4 | Screen | framebuffer console, then a real panel driver at 60 Hz, then 120 Hz, then touch |
| M5 | Untethered | charging and fuel gauge, audio if it is cheap |

## Risks

| Risk | Mitigation |
|---|---|
| Foldable panel never comes up | `simple-framebuffer` first (LK leaves the panel scanning out), so there is a console before the real driver exists |
| Two-encoder DSC needs DPU/DSI changes, not just a panel driver | panel first at 60 Hz; the DSC config is identical across all four timing sets |
| No accessible UART | USB gadget console, pstore, and a boot that is observable from the outside |
| ABL rejects the image | reuse the stock `mkbootimg` arguments verbatim; `SEANDROIDENFORCE`; `vbmeta_disabled` as the last resort |
| Charger driver missing | trickle charging at the hardware default plus download-mode charging; not a gate for a toy |
| Bootloop protection | download mode plus the full stock AP tar is always enough |

## Effort

M1 is a weekend or two. M2 is the first real chunk of work (1–3 weeks). M4 is the part
with an open-ended tail: the panel driver is plausibly days now that the init sequence and
timings are known, but the DSC pair path in mainline is the unknown.
