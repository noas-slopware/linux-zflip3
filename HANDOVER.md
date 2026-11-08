# Handover — 2026-11-06

Copy everything below the line into a new session. The first thing that session must do is read
`HANDOVER.md` and `AGENTS.md` in this repo.

---

## Goal

Mainline Linux (Arch Linux Ports aarch64 userspace) on a Samsung Galaxy Z Flip3 5G,
`SM-F711N` (codename `b2q`, Korean `LUC`/OKR). Repo: `noas-slopware/linux-zflip3`,
working tree `/home/yuifunami/linux-zflip3`. Branches: `senpai` (patches/tools/userspace),
`docs` (write-ups), `firmware` (vendor blobs). Read `AGENTS.md` in the repo first — it
carries the device-access rule and the hard-won flasher facts.

## Rules that matter

- **No device access without an explicit request in that message.** No adb, no heimdall,
  no usbip-helper, not even reads. Local build/DTS/git work is fine.
- No stock/vendor kernel as a product — Noa rejects it as ancient.
- No external hardware (UART jigs, JTAG, test points) and no exploit hunting.
- Say what a device action is for in one or two lines, then wait.

## What is established (verified on the unit)

- Bootloader unlocked: `ro.boot.flash.locked 0`, `verifiedbootstate orange`, `OEM LOCK: OFF (U)`.
- Boot chain is header **v3**; `boot.img` has kernel + ramdisk and **no dtb**; the dtb lives
  in `vendor_boot.img` (board string `SRPUC29A015`); `dtbo` holds 7 overlays.
- ABL **does** boot our images. The Korean "이 휴대전화에 현재 삼성 공식 소프트웨어가…" screen is
  the normal non-Samsung-OS warning, not a refusal.
- **Mainline kernel runs on Samsung's own DT** (no reset for 60 s+), so kernel and loading
  are sound. It cannot get USB there: Samsung's tree uses `qcom,dwc-usb3-msm` with
  downstream clocks/PHYs, and mainline `dwc3-qcom` needs mainline providers.
- **Our own DT kills it before init.** Eliminated by test: memory node (both ABL-patched
  zeros and hardcoded 8 GiB), the 26 Samsung reserved regions, and the GCC clock driver
  (`&gcc { status = "disabled"; }` still resets). Even a core-only tree resets.
- A valid-header kernel whose entry is an infinite loop is refused the same way, so the
  refusal path is consistent and content-related only via the DT.
- Live DT identity from the device: `compatible = "QCOM,LAHAINA-MTP"`, model
  "Samsung B2Q PROJECT", `board-id 08`, RAM 7.2 GiB usable.
- **Panel is Samsung `SVC_OCTA`** (`SVC_OCTA2`, `SVC_OCTA_CHIPID`, …). The earlier
  BOE/Synaptics `sw43404` plan came from a third-party decompile and is wrong for this unit.
- Stock kernel config (extracted from the Image, `IKCFG_ST`…`IKCFG_ED`): **no
  `CONFIG_USB_G_SERIAL`**, no `CONFIG_VT`, no fbcon; `SERIAL_MSM_GENI_CONSOLE=y` but no
  wired UART. So that kernel can never give a kernel console, and `/dev/fb0` does not
  exist, which is why painting it changed nothing.
- USB **descriptor strings** are a working one-way readout on the stock kernel (that is how
  the panel and board-id were obtained). ~300 bytes, needs a re-bind to refresh.
- Writing 0xff over the splash region (`0xe1000000`, 12 MiB) from an `early_initcall` did
  **not** change the panel, so that buffer is not what is being scanned.

## Flashing

- Use **heimdall** (`heimdall-flash`, Debian) on `yuruyuri-san-hai` (192.168.0.6).
  `odin4` fails the handshake on this device every time — do not bother.
- `adb` also lives on san-hai: `ssh yuifunami@192.168.0.6 "sg plugdev -c 'adb …'"`.
- usbip cannot carry this phone in Android mode (it re-enumerates on bind); download-mode
  flashing over usbip is unreliable too. Flash natively on san-hai.
- Image layout that boots: `boot` = kernel + initramfs, `vendor_boot` = dtb,
  `vbmeta` = **flags 3 with no descriptors** (a vbmeta that *has* descriptors causes the
  "unauthorized software" screen), `dtbo` = stock or a single no-op overlay,
  `SEANDROIDENFORCE` appended to `boot`/`recovery` only.
- Manual download mode: power off, hold VolUp+VolDn, plug in. `adb reboot download` works
  only when Android is booted. The D2 screen means a secure lock is set. A flat battery
  looks identical to a dead bootloader.
- After a failed boot the phone lands in fallback download mode and ABL's failure
  accounting seems to distrust the slot; that is why repeated probes cost extra.

## State of the tree

- `patches/linux/0001-…` board DTS (derived from MTP, currently the crashing one),
  `configs/b2q-m1.fragment`, `tools/` (extract-firmware, bootimg with `--vendor`,
  build-kernel incl. the TYPEC/PHY tristate traps, build-initramfs, build-rootfs,
  gateway check `tools/gate.sh`, `tools/phone-usb.sh`).
- `.cache/linux-7.3.1` built tree; `out/` has the images; `evidence/raw/` has the stock
  boot/recovery/vendor_boot/dtbo/vbmeta and decompiled trees; `evidence/SM-F711N-m0.md`
  and `docs/gate.md` hold the facts and the KG/VaultKeeper write-up.
- Kernel trees carry local experiments: `drivers/soc/qcom/b2q-paint.c` (splash paint) and
  `sm8350-samsung-b2q{,-min,-core}.dts`.

## The open problem, and the plan

Why does our DT reset before init? Remaining suspects are the core providers that bind
only in our tree (Samsung's compatibles differ so their kernel never probes them):

1. `qcom,sm8350-pdc` at `0xb220000` (Samsung: `qcom,lahaina-pdc`)
2. RPMh power-domain / clock controller (`rpmhpd`, `rpmhcc`)
3. SPMI + PMIC nodes (`pm8350*`, `pmk8350`, `pmr735*`)
4. SMMU / LLCC / bwmon
5. TLMM pinctrl

Plan: build five DT variants, each enabling one more of these on top of the surviving
core, and flash them in order; each result eliminates a block permanently. Everything is
local except the flashes. The bisect only works if each step changes exactly one thing.

Longer term, the correct structure is our DT rebuilt as a translation of the vendor tree,
not authored from MTP: the vendor tree is `qcom,lahaina-mtp` board-id 08.

## What not to repeat

- Do not flash repeatedly without asking.
- Do not chase consoles that the target kernel cannot provide; check the kernel config
  (`IKCFG_ST`) before building a channel.
- Do not change dtbo, vbmeta, DT and kernel in one step.
- Do not claim a mechanism without a source in `docs/` or a dump in `evidence/`.
