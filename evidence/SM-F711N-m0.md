# M0 device dump, 2026-11-06

Sanitised summary of the read-only evidence pull (`tools/evidence.sh`). Raw dumps are in
`evidence/device/<timestamp>/`, which is gitignored because they carry the device serial.

## Identity

| | |
|---|---|
| model | SM-F711N |
| codename / product | `b2q` / `b2qksx` (Korean, LUC sales code) |
| CSC | LUC (LG U+), OKR multi-CSC |
| build | `F711NKSSFKZH5`, Android 15 / One UI 7 (`AP3A.240905.015.A2`) |
| security patch | 2026-08-05 |
| baseband | `msm` (integrated Snapdragon 888 modem) |

## Unlock gate

| | | verdict |
|---|---|---|
| OEM unlocking (Developer options) | on | ok |
| `knox.kg.state` | `Completed` | ok, not Prenormal |
| `ro.boot.flash.locked` | `1` | **still locked** |
| `ro.boot.verifiedbootstate` | `green` | still verified boot |
| `ro.boot.warranty_bit` | `0` | Knox not tripped yet |

So the toggle is on and nothing blocks the unlock, but the bootloader itself has not been
unlocked. That happens in download mode with a long press, and it wipes userdata. Expect
`verifiedbootstate` to become `orange` and `warranty_bit` to stay `0` until the first
non-stock image boots (it flips to `1`).

## Storage layout (measured, 256 GB model)

| partition | device | size |
|---|---|---|
| `boot` | sda19 | 96 MiB |
| `recovery` | sda20 | 96 MiB |
| `vendor_boot` | sda21 | 96 MiB |
| `dtbo` | sda22 | 24 MiB |
| `metadata` | sda25 | 16 MiB |
| `super` | sda26 | 14040 MiB |
| `userdata` | sda37 | 227206 MiB |
| `efs` | sda6 | 20 MiB |
| `persist` | sda5 | 32 MiB |
| `param` | sda7 | 10 MiB |

Two surprises against the LineageOS `b2q` device tree:

1. `super` is 13.7 GiB here, not the 12067012608 bytes (11.2 GiB) that tree declares.
   Firmware grew it. The storage plan uses it as `/`, so the larger size is good news.
2. There is a **`vendor_boot`** partition. The Android 11-era tree builds a header v2
   `boot.img` with the kernel and ramdisk inside, and no vendor_boot. Whether ABL on this
   firmware wants anything from `vendor_boot` is an M1 question; the stock image's own
   `mkbootimg` arguments (from `tools/extract-firmware.sh`) will settle it either way.

## Not readable without root

`/proc/cmdline` is `Permission denied` on Android 15. The ABL command line therefore has to
come from the stock `boot.img` header (M0 extraction) rather than from the running system.

## The boot chain is header v3 with the dtb in vendor_boot

Unpacking the stock AP tar (F711NKSSFKZH5) corrects what the LineageOS `b2q` tree implies:

| image | header | contents |
|---|---|---|
| `boot.img` | v3 | kernel, ramdisk (723409 B), command line, **no dtb** |
| `vendor_boot.img` | v3 | **dtb (1433155 B)**, vendor ramdisk (695382 B), `board = SRPUC29A015` |
| `dtbo.img` | — | 7 overlays, 24 MiB; panel definitions live here |

So M1 is two images, not one:

- `boot.img`: v3, our kernel + our initramfs, no dtb
- `vendor_boot.img`: v3, our dtb + a (possibly empty) vendor ramdisk

The board string on this firmware is `SRPUC29A015`, not the `SRPUC03A002` the old
LineageOS tree hardcodes, which is exactly why `tools/bootimg.sh` reads it from the stock
image instead.

The dtb only carries the platform (`chosen { bootargs = "log_buf_len=256K ..." }`, no
panel nodes); every panel variant is in the dtbo overlays, and the phone picks one at
runtime by reading the panel ID. Candidates found in the overlay, all present in all 7
entries:

- `sw43404 amoled ... boe panel with DSC` (the Synaptics TDDI one)
- `ss_dsi_panel_S6E3HAD_AMF670ZA01_FHD` and `S6E3HA9_AMF670UH01_FHD` (Samsung DDICs)
- `r66451 amoled ... visionox`, plus the cover panels `S6E36W3 ... 260X488` and `116X300`

Which one is actually in this unit is not yet known: `/sys/class/lcd/panel` is root-only,
so it needs either root or the first Linux boot to read the DDIC ID. Not needed before M4.

## Display modes, from the running system

`dumpsys display` on the stock ROM reports the main panel as 1080x2640 with modes 120 /
96 / 60 / 48 Hz and HDR types 2/3/4; the cover is 512x260 at 60 Hz. That matches the
`fhd*` timing sets in the overlay, with 48 Hz as an extra alternative rate.

## TZ-reserved TLMM pins, from the stock kernel

Samsung's `lahaina` pinctrl driver in the stock `boot.img` kernel (`evidence/raw/boot/kernel`,
F711NKSSFKZH5) carries its own `reserved_gpios` list. The `msm_pinctrl_soc_data` struct is
at Image offset `0x23a11d8` (npins 212, nfunctions 183, ngroups 212, ngpios 205); its
`reserved_gpios` field is a `R_AARCH64_RELATIVE` relocation to `0x23a79b8`, which holds:

    4, 5, 6, 7, 40, 41, 52, 53, 54, 55, 56, 57, 58, 59, -1

Qualcomm's own `pinctrl-lahaina.c` reserves only 52..59, which is also what the upstream
SM8350 MTP and HDK trees put in `gpio-reserved-ranges`. Samsung adds 4..7 and 40..41.

Mainline `pinctrl-sm8350` reads every valid GPIO's config register while registering the
gpiochip (`gpiochip_add_data_with_key()` calls `get_direction()` per line), and firmware-owned
TLMM pins reset the board when touched (Caleb Connolly, "pinctrl: qcom: handle reserved
ranges", u-boot list, April 2025). Samsung's DT never binds the mainline driver
(`qcom,lahaina-pinctrl`), ours does, and none of our trees reserved 4..7 or 40..41.

Measured on the unit (2026-11-06): with 4-7, 38-41 and 52-59 reserved, the mainline TLMM probe
still reset the board. A temporary print before every `msm_gpio_get_direction()` read showed
the last read was **gpio30**. In the stock DT, gpio30/31 are only the pins of `qupv3_se6_2uart`,
which is disabled for Linux (SE6 is used as I2C for the front-camera EEPROM). 30-31 are reserved
together; 31 itself has not been read.

## First mainline boot to userspace (2026-11-06)

Raw ACM session and dmesg: `evidence/device/20261106-mainline-first-boot/` (gitignored).

Recipe: boot.img header v0, Image.gz + appended DTB (Nura `sm8350-samsung-b2q.dts` with
`gpio-reserved-ranges = <4 4>, <30 2>, <38 4>, <52 8>` and a ramoops node at Samsung's
`0xf0b00000`), dtbo zeroed, kernel 7.3.1 built with the Nura sm8350 config plus
`CONFIG_CMDLINE_FORCE`. ABL replaces our boot.img command line (the stock vendor command line
starts `console=null` and ends `panic=4`), so the command line is built into the kernel.

From the session:
- all 8 CPUs up at EL1, PSCI 1.1 with OSI; 7325772K of 8311808K available
- simplefb at `0xe4000000`, 1080x2640 a8r8g8b8, drives the panel as tty0
- UFS: `SAMSUNG KLUEG8UHDC-B0E1`, 6 LUNs, sda has 37 partitions
- USB peripheral: configfs ACM gadget enumerates, but only after the cable is re-plugged
- SPMI SID 3 (PM8350B) gives `transaction failed (0x3)`; Samsung's DT has no PM8350B, so the
  Volume Up key on pm8350b gpio6 in the Nura DT never probes
- `990000.i2c` defers on its TX DMA channel (no GPI DMA)

Product image (`tools/build-kernel.sh` + `tools/mkimages.sh`, board DTS from `patches/linux/0001`)
booted the same way. Without `pm8350b.dtsi` the SPMI `transaction failed` warning is gone, and
Volume Up on PM8350 gpio6 registers as `input0` (`gpio-keys`). Raw: `evidence/device/20261106-product-boot/`.

## Arch Linux Ports running from UFS (2026-11-06)

`super` and `userdata` are now LVM PVs in VG `b2q`; LV `root` (235.6 GiB) is F2FS. The
initramfs mounts it and switches to systemd. Over USB NCM, `ssh root@172.16.42.1` (via the
host the phone is plugged into) reports: Arch Linux, kernel 7.3.1, `systemctl
is-system-running` = running with no failed units, 8 CPUs, 7195 MiB RAM, 133 packages.
There is no RTC driver yet (`RTC time: n/a`), so the clock starts wherever systemd's
timestamp leaves it.

## USB needs no re-plug once the MAX77705 data switch is closed (2026-11-06)

After a warm reboot the phone never connected over USB (flash host dmesg: no connect at
all on 7-3.2, not even failed descriptor reads) until the cable was re-plugged; only
boots straight out of download mode enumerated. The USB-C D+/D- lines run through the
MAX77705's Type-C block (I2C 0x25 on the `i2c7`/0x99c000 bus, PMIC at 0x66 reads
PMICID1 0x15, PMICREV 0x02 = "MD15 PASS2" in Samsung's driver; USBC HW rev 0x1a,
FW rev 0x65). Its switch is set through the opcode mailbox (Samsung `max77705-muic.c`,
`max77705_switch_path`): opcode at 0x21, data at 0x22, execute by writing 0x41.

    i2cset 5 0x25 0x21 0x05; i2cset 5 0x25 0x41 0; i2cget 5 0x25 0x52  -> 0x3f (D+/D- open)
    i2cset 5 0x25 0x21 0x06; 0x22 0x09; 0x41 0                         -> host enumerates 1d6b:0104

Fixed in Linux (patches/linux/0002, 0003: accept MD15 PASS2, close the switch at probe,
open it at shutdown like the vendor driver) and U-Boot (patches/u-boot/0010).

## GPU (Adreno 660) renders headless (2026-11-06)

`msm.separate_gpu_kms=1` binds the GPU without MDSS, so the display stays on simplefb.
The zap shader is Samsung-signed: `image/a660_zap.{mdt,b00..b02}` in NON-HLOS.bin from
the BL tar, squashed to `qcom/sm8350/Samsung/b2q/a660_zap.mbn`
(sha256 d9cf69f636557238dd79f8910a5cf0d89049e8a8927841fc3f5ff94911e4806c);
SQE and GMU firmware come from linux-firmware (`Loaded GMU firmware v3.1.10`).
The first probe at boot fails and the retry hit `-EBUSY` on the GMU's devm-mapped RSCC,
then PDC region (patches/linux/0004 fixes it). Mesa 26.2.6: `FD660`, OpenGL 4.6 /
ES 3.2 surfaceless; an FBO clear read back with glReadPixels returns the cleared colour.

## MAX77705 INTB is PM8350C GPIO5 on VIN1 (2026-11-06)

Once the MAX77705 core probed, IRQ 159 (PM8350C GPIO5, level low) fired 100k times
and was disabled ("irq 159: nobody cared") about two minutes into boot, although
INTSRC, CHG_INT, the USBC interrupt registers and the fuel gauge STATUS all read clear.
The pad was configured with `power-source = <0>`; stock `if_pmic_irq` (dtbo entry 3)
uses `power-source = <0x01>`. On VIN0 the input read low regardless; on VIN1 it reads
high and the interrupt count stays at 0. Separately, the bootloader leaves the USBC
block's interrupt masks open (UIC_INT_M 0x04, CC_INT_M 0x20, PD_INT_M 0x00,
VDM_INT_M 0xf0) and our CONTROL1 opcode completes with UIC_INT 0x80, so the core
masks and clears those too (patches/linux/0003).

## Main touchscreen: FTS9CU80F on i2c4 0x49, Samsung command set (2026-11-06)

i2c4 (QUP SE4, 0x990000) never probed: its GPI DMA controller `gpi_dma0` was disabled
("geni_i2c: Failed to get tx DMA ch"). With it enabled the controller answers at 0x49:
`0x22` -> `53 54 50`, `0x24` (firmware) -> `01 10 00 30 30 13 13 04`, `0x23` (panel
info) -> `0f ff 0f ff 0f ff 0f ff 11 2a 00` (0..4095 per axis). Samsung's driver
(GPL tarball, `drivers/input/sec_input/stm_fold`, compatible "stm,stm_ts") uses the
sec_ts command set, not ST's FTM protocol (mainline stmfts, the FTS5 series). By hand:
reset `fa 20 00 00 24 81` -> `49 00` (status/INFO/READY); `30 61 00` -> echo
`43 01 30 61 00`; `13` -> `43 01 13`; `62`; `a0 00 01` -> `43 01 a0 00 01`.
Supplies: s2dos05 LDO2 (1.8 V, vdd) and LDO3 (3.0 V, avdd); IRQ TLMM 23 level low.
Driver: patches/linux/0005.
Touch test (evtest, Noa tapping): top-left 445,211; top-right 3695,271; bottom-left
474,3789; bottom-right 3690,3791; a downward swipe goes 1854,2184 -> 1776,2974; two
fingers in slots 0 and 1; a palm reports ABS_MT_TOOL_TYPE 2 (MT_TOOL_PALM). Axes need no
swap or inversion.

## Display takeover timing (2026-11-06)

With the panel, i2c-gpio and S2DOS05 built in, DPU binds at ~1.5-1.9 s instead of ~10 s.
Trace (dyndbg on the panel, `trace_event=dpu:dpu_enc_phys_cmd_pp_tx_done`, kernel #20 +
debug prints): prepare 1.630, display on 1.809, first frame transferred 1.851; frames
then every 16.7 ms. The ~42 ms between display on and the first frame shows the GRAM
noise left by the panel reset. Skipping the reset on the bootloader-handed-over panel
(init sequence only) was much worse: the screen was garbled for good and Noa pulled
the phone into download mode; recovery was reflashed with the #20 image
(764394ed3bd0...). Not repeated.

## The main panel is S6E3HAD_AMF670ZA01 rev D, not S6E3FAC (2026-11-07)

The 60 Hz lock came from driving the wrong panel. The dtbo's `qcom,dsi-default-panel`
is B4_S6E3FAC_AMF670BS01, but stock picks the panel by ID at boot, and this unit's ID
belongs to `ss_dsi_panel_S6E3HAD_AMF670ZA01_FHD` (dtbo `/fragment@119`):

- ID DA/DB/DC = 91 10 46. HAD's `ss_panel_revision()` switches on ID2 (DC) and lists
  `case 0x46: 'D'` explicitly; FAC's switches on the low nibble of the ID and has no case
  for 6 ("Invalid panel_rev").
- The DDI behaves like HAD's commented register map (`ss_dsi_panel_S6E3HAD_AMF670ZA01.c`,
  `#if 0` block): f2@0x03 = 50 and f2@0x44 = 80 are HAD's NS oscillator values, `60` is
  HAD's two-byte FREQ register, and the frame period follows HAD's VFP2 (f2@0x0d):
  writing 02 c4 there gave TE 48. FAC's VFP fields (f2@0x08, f2@0x11) do nothing.
- Scan rate from DCS get_scanline (0x45) with dmesg timestamps: 161.5 k lines/s
  (60 Hz) after the FAC init sequence.
- Clean test without a build: reset pulse on TLMM 22 via /dev/mem (0x0f116004 = 0, then 2),
  then HAD's stock fhd120hs on-command from the dtbo over the debugfs DCS file (pre-11 part,
  `11`, 120 ms, rest; compression-mode and PPS packets left out because the debugfs file
  can't send those types), then `29`. Result: TE 119-120/s (high 148 us, low 8.25 ms),
  scanline 324 k lines/s = 119.5 Hz. `fb0` blank/unblank brings the FAC init and 60 Hz back.
- HAD's PPS is FAC's 89 bytes plus 31 zero bytes, so the image path is unchanged.
- Kernel #39 with `panel-samsung-s6e3had` built in (stock HAD sequences, DTS compatible
  `samsung,s6e3had-amf670za01`, MSM batching + `hs_rate` 910 Mbps): TE 120/s (high 125 us,
  low 8.21 ms), page flips 118.7 Hz, dsi0vco 909.999 MHz.
- Kernel #40, same driver without the MSM edits (no batching, no `hs_rate`): link 867 Mbps,
  TE 114-115/s (low 8.61 ms), flips 114.5 Hz. The panel's frame rate scales with the DSI
  link rate (867/910 x 120 = 114.3). A KMS mode with pixel clock 397612 kHz (same porches)
  brings the link to 910 Mbps on the unmodified MSM driver and TE back to 121/s, so
  batching is not needed; only the link rate is.
- Kernel #41/#44, no mainline edits: each mode's horizontal front porch is stretched so
  MSM lands on 910 Mbps (fhd120hs: htotal 1186, 909.93 Mbps). TE 120/s, flips 120.2 Hz.
- Stock's VRR sets switch the panel live, HS and NS both ways (debugfs, kernel #42):
  96HS TE 96, 60HS 59-60, 48HS 48, 60NS 60, 48NS 49, 120HS 119-120.
- Kernel #44 offers fhd120hs, fhd60hs and fhd60ns as DRM modes (full modeset on change):
  flips 120.2 / 60.07 / 60.03 Hz, TE 120 / 60 / 60. In 60NS f2@0x03 reads 50 and b9 01; in
  60HS f2@0x03 reads 00 and b9 11 (TE every 2 frames). 96/48 left out: stock corrects their
  gamma from the panel flash (ss_gm2_gamma_comp_init), not ported.
- LFD (the 10 Hz idle floor in 120HS) is written as stock and reads back (bd@0x06 =
  00 2c 14 00 01, bd@0x17 = 40), but whether the panel drops its refresh when idle is not
  verified: TE stays at the base rate by design (b9 09; 00/01/08/41 change nothing), and
  scanline reads are answered on a fixed line, so neither shows it.
- A hot swap (unbind the built-in panel driver, insmod a test module) rebound DRM but hung
  the phone right after; it needed a forced reboot.
- HAD's 120HS block sent live on top of the FAC init stops the scan (TE 0, scanline 0),
  and so does HAD's full on-command after a sleep-in/out on top of it: something in the
  FAC init (f6/f4/f2@0x33 writes) breaks HAD's HS oscillator. Only a reset plus the HAD
  sequence works.

## Panel refresh stuck at 60 Hz (2026-11-07, solved above)

- TE measured on the pin (TLMM 82 via /dev/mem, ~3.2 M samples/s): 60 rising edges/s,
  idle and during continuous page flips; DPU's read-pointer IRQs agree; frame transfer
  ~6-7.5 ms after each TE. DPU side checked: vsync clock 19.2 MHz, external TE connected.
- No effect on TE: stock vrr_tx_cmds for 120HS/96HS/48HS (one by one in LP, or as one HS
  burst with 9f/f0/fc keys, with or without the f1 key), TE_FRAME_SEL 01/03, DSI link at
  ~980 Mbps instead of 867. A continuous DSI clock left the screen black (reverted).
  OSC `60 18` (60NS) stopped TE until the panel was re-initialized.
- Read-back (DCS read after B0 offset): DA/DB/DC = 91 10 46; 0A = 9f; f2@0x08 = 00 20 and
  b9@0x0c = 05 28 hold what is written; b9@0 reads 01 00 01 for 61 00 01; bd@0..1 =
  01 21 (bd e3 21 lands), but bd@0xad and bd@0x7b.. stay 00 after writing 12 and the
  frame-insertion bytes, as DCS or generic writes, inside or outside bd e1 ... bd e3 21.
  The VRR/LFD part of bd does not take writes; that is where the rate is set.

## RTC: PMK8350, read-only, offset in SDAM14 (2026-11-07)

- Stock dtbo (`evidence/raw/dtbo/entry.3`, `pmk8350_rtc: rtc@6100`): `qcom,pmk8350-rtc`,
  reg 0x6100/0x6200, irq `<0 0x62 1 1>`, no `allow-set-time`, no nvmem. Stock defconfig
  `b2q_kor_singlex_defconfig`: `RTC_DRV_PM8XXX=y`, `RTC_HCTOSYS=y`. Android keeps the
  offset in userspace (time_daemon).
- The counter runs: 0x6146 = 80 (enabled), 0x6148..b read 0x07cd.... (about 130.94 M s,
  February 1974 as epoch time).
- SPMI arbiter v5 ownership (core 0xc440900 + 4n for the APID map, cnfg 0xc40a700 + 4n for
  the owner EE; Linux is EE 0): ppid 0x061 (RTC write) is APIDs 69 and 200, owners EE 1
  and EE 4, so Linux cannot set the counter. ppid 0x062 (alarm) is EE 0. SDAMs owned by
  EE 0: 0x71, 0x7c, 0x7d, 0x84, 0x85, 0x98, 0x9d; 0x70 is EE 1.
- Stock references SDAM2 (restart reason), SDAM3 (PON reason), SDAM5 (PON log),
  SDAM21/22 (LPG); SDAM13/14/46 are declared but unreferenced. SDAM14 0x45..0xbf read all
  zeros, so the offset goes to SDAM14 0xbc, 4 bytes (as sc8280xp-crd does in its SDAM6).
- Kernel #45: rtc0 registered; after the first NTP sync 0x7dbc..bf = 1d 22 20 63
  (0x6320221d). After a reboot, hctosys set the clock to 2026-11-06T17:51:43 UTC from
  the RTC before any network. `rtcwake -m on -s 3` fires `pm8xxx_rtc_alarm` (count 0 → 1).
  Wake from suspend and power-on alarm are untested.

## Haptics: MAX77705 LRA on GCC GP2 (2026-11-07)

- Stock dtbo (`entry.3`): `max77705_vibrator` (`LINEAR_0832RC`, haptic,frequency 0x802
  = 205.0 Hz, normal_ratio 73, overdrive_ratio 95, vib_power gpio190 high) with
  `pwms = <&pwm_gpclk 0 1000000>`; `samsung,pwm_gpclk` at 0x165000 (GCC GP2), gpio116
  in `gcc_gp2`. Stock's period is 78125000 / 2050 = 38109 ns (26.24 kHz, / 128 = 205 Hz);
  `pwm-gpclk.c` runs the root from XO / 16 (1.2 MHz), M 2 or 3, 8-bit N, D = ~(2 * N *
  duty / period).
- Left by the bootloader: MAX77705 MAINCTRL1 0x81 (BIASEN on), MCONFIG 0x82 (LRA, /128),
  GP2 CFG 0x201f, M 3, N 0x78.
- From userspace over /dev/mem and i2cset (gpio190 high, gpio116 → gcc_gp2, M 2 N 92,
  D 73 %, MCONFIG 0xc2): Noa felt 3 buzzes.
- Kernel #46 (pwm-qcom-gp + mainline max77693-haptic): `max77693-haptic` input device;
  during a full-strength FF_RUMBLE: GP2 CBCR 0x1, CFG 0x201f, M 3, N reg 0x79 (N 137,
  26.28 kHz, 205.3 Hz), D reg 0x37 (100 / 137 = 73 %), MCONFIG 0xc2; CBCR 0x80000000
  after. Noa felt it. feedbackd tags it as its vibra (72-feedbackd.rules lists
  max77693-haptic), and the Plasma Mobile lock screen keypad vibrates per tap.
- Not ported: stock's 95 % overdrive at the start of an effect, the per-fold-state and
  high-temperature ratios.

## Fold sensor and suspend (2026-11-07)

- Stock dtbo `hall_ic` / `flip`: gpio80 active low, event 0 (Samsung's SW_FOLDER, which is
  SW_LID), 50 ms debounce, `folder_hall_irq` gpio80 input, no pull. Watched over the GPIO
  chardev while Noa folded the phone: falling on close, rising on open.
- gpio-keys `switch-fold` (SW_LID, wakeup on deassert only). logind: "Lid closed",
  PowerDevil (holds the handle-lid-switch inhibitor) suspends.
- `deep` (PSCI SYSTEM_SUSPEND) resets the phone. Stock never calls it: its suspend_ops are
  lpm-levels' (`lpm_suspend_enter`, CPU_SUSPEND to the deepest level), the s2idle path.
- s2idle reset too. With PM_DEBUG: pm_test `devices` resumes, `platform` resets, also with
  ath11k_pci unloaded. Cause (same as the REDMAGIC 6, SteamOS-ARM-Handhelds kernel-sm8350
  0014): genpd switches pcie_0_gdsc off in noirq while the link is up. Patch 0009 keeps
  the PCIe GDSCs in retention (as SM8450/SM8550/SC8280XP).
- Kernel #48 + `mem_sleep_default=s2idle`: `rtcwake -s 15 -m mem` sleeps 03:47:10 to the
  alarm, back 03:47:28. Lid: closed 03:49:22.66, suspend 03:49:23.32, opened 03:49:34.69
  (gpio-keys wakeup_count 1), resumed 03:49:34.71; Noa saw it wake.
- ramoops at 0xf0b00000 (and a test region at 0xc8000000) is empty after every reboot,
  clean or not: DRAM does not survive here, so pstore gives nothing.

## Fuel gauge (2026-11-07)

- Stock `max77705-fuelgauge` at i2c7 0x36: fg_resistor 5. Samsung's driver scales by
  fg_resistor / 2 against 5 mOhm (1 = 10 mOhm, 2 = 5 mOhm), so 5 is 2 mOhm; capacity 0x4b0
  * 5 / 2 = 3000 mAh, as stock reports.
- STATUS 0x0080 (no POR), so mainline max17042 (maxim,max77705-battery, rsns 2000) writes
  nothing but the SOC alert config. Kernel #48: capacity 99 %, 4.269 V, -303 mA,
  charge_full_design 3000000, charge_full 2800000, temp 30.0 C; UPower sees it.
- Dual cells behind two S2ASL01 current limiters on i2c1 (0x38 main, 0x39 sub), both
  answer; charger at 0x69 as left by the bootloader: CNFG_00 0x05, CNFG_02 0x4a (CC
  500 mA), CNFG_04 0x13 (CV 4.35 V), CNFG_08 0x00, CNFG_09 0x93.

## Charger and dual-cell limiters (2026-11-07)

Ported by two subagents; their source-cited reports are `evidence/reports/max77705-charger.md`
and `evidence/reports/s2asl01-limiter.md`. Patches 0010 (charger setup like stock, BC1.2
from the USB-C block, cable-info currents), 0011 (binding), 0012 (S2ASL01 driver).

Kernel #48 (+ DT), phone on the flash host's USB port (a PC port, SDP):
- charger: online, input 475 mA / charge 550 mA (stock cable-info USB), CNFG_02 0x4b,
  CNFG_03 0xb8 (150 mA / 70 min), CNFG_04 0x1c (4440 mV), CNFG_08 0x00 (3 MHz), CNFG_09
  0x92 (CHGIN_LIM 475 mA, stock encoding), CNFG_12 0x68 (VCHGIN 4.6 V, CHGINSEL).
  Before: CNFG_02 0x4a, CNFG_03 0xd9, CNFG_04 0x13 (4350 mV), CNFG_09 0x93.
- limiters: main ID 0x91 (6130 rev 1), sub ID 0x90 (6030 rev 1); fast charge limit 0x12
  0x0d -> 0x20 / 0x1e (1650 mA, the stock driver default), the rest as the bootloader
  left it and as stock writes it. CORE_CTRL1 (0x0f) bit 0 (EOC on) is written but reads
  back 0 on both.
- fuel gauge with `power-supplies = <&max77705_charger>`: status Full, UPower
  "fully-charged" 99 %, line power online.
- Not ported: stock's split of the charge current between the cells
  (sec_bat_divide_limiter_current, zones 40/85, 33/77, 46/60 %) and per-cell full
  detection (sec-dual-battery), AFC 9 V and USB-PD, the charger watchdog (stock only
  kicks it from its polling loop). Charging current itself is untested: the battery was
  full.

## Dual cell charging, AFC and USB PD (2026-11-07)

Patches 0013-0016 (charge_behaviour, AFC/PD over the USB-C opcode mailbox, limiter
properties, samsung-dual-battery). Stock sources: sec_battery.c 275-337 (zone split),
2093-2195 (full checks), 2260-2300 (do_fullcharged), 1560-1626 (recharge), 455-528 (PDO
index), 6100-6340 (PD limits); sec_dual_battery.c 18-140 (cell EOC, 30 min force);
max77705-muic-afc.c 51-83, 145-200, 250-560 (AFC); max77705_pd.c 134-200, 505-560, 813-900,
1483-1525 (PD); dtbo entry.3.dts 84-169, 955-975 (values), 9593 (snkcap_data).

Kernel #52 on the phone:
- SET_SNKCAP at probe answered (no timeout); UIC_INT_M 0x5d, PD_INT_M 0xbf.
- PC port (SDP): 475/550 mA, limiters 200/450 mA (zone 1, 40/85 %). Charger had ended
  by itself (CHG_RSTRT off, as stock) at 98 %: "charger terminated -> full ->
  recharging", CNFG_00 back to 0x05.
- USB PD charger (Noa's, C to C): "PD: PDO 1 -> 2 (9000 mV)", "PD: 9000 mV, input 1666 mA,
  charge 2850000 uA"; CNFG_09 limit 1650 mA, USBC_STATUS1 VBADC 0x6 (8.5-9.5 V);
  limiters 900/2150 mA (zone 2, 33/77 %).
- In top-off (CHG_DTLS 3, which mainline reports as Full) at 4.42 V: second stage, cell 0
  full 4413750 uV / 34375 uA, cell 1 full 4421250 uV / 67187 uA, both limiters
  inhibit-charge (supplement), charger inhibit-charge, CNFG_00 0x04 (buck only).
- AFC is untested on the device (no AFC brick at hand). QC 2.0, PPS, age steps (stock
  takes batt_cycle from userspace; without it stock stays at step 0 too) and the
  thermal current overrides are not ported.

## Cellular: firmware staged, DT verified (2026-11-07, host side)

Subagent reports: `evidence/reports/cellular-dt-check.md` (stock DT vs ours).
No device action yet; nothing on the phone has changed.

- `tools/extract-qcom-firmware.sh` now also reads the CP tar (`--fat modem.bin`),
  which holds `image/modem.{mdt,b00..b27}` (b09/b16 absent: those phdrs are
  `filesz 0` and `pil-squash.py` skips them). Squashed:
  `qcom/sm8350/Samsung/b2q/modem.mbn` 88596620 B sha256 `9f842fd3...4a5230e4`,
  `ipa_fws.mbn` 37832 B sha256 `bd2e40e3...849d9d5b2` (ipa_fws from NON-HLOS.bin,
  whose `image/ipa_fws.*` it already knew how to reach). `a660_zap.mbn` unchanged.
- `modem.mbn` is linked for 0x8b800000-0x9ae00000 exactly: last PT_LOAD ends at
  0x9a24f000+0xbb1000 = 0x9ae00000, the end of our `pil_modem_mem`
  (0x8b800000+0xf600000). The image's own phdrs confirm the region; so does stock,
  whose dtbo fragment 165 shrinks the base DTB's 0x10000000 to the same 0xf600000.
- Stock IPA regions equal the sm8350 dtsi defaults we inherit: `pil_ipa_fw_mem`
  0x8b500000/0x10000, `pil_ipa_gsi_mem` 0x8b510000/0xa000. Stock loads the IPA
  firmware through a separate `qcom,pil-tz-generic` node with `qcom,pas-id = 0x0f`,
  which equals mainline's `IPA_PAS_ID` 15 with `qcom,gsi-loader = "self"`.
- The mpss node needs nothing else: pas_id 4, smem 421, minidump 3, ssctl 0x12 and
  the smp2p entry names all match between stock and the `qcom,sm8350-mpss-pas`
  descriptor. `auto_boot` false on both sides, stock included.
- Known non-cellular wart found: b2q's `pil_camera_mem: memory@9b800000` merged with
  the dtsi `rmtfs_mem` node (same unit address), so the built dtb has one node there:
  rmtfs compatible with the camera region's 0x500000. `/dev/qcom_rmtfs_mem1` exists,
  rmtfs gets a 5 MiB window (dtsi default 2.5 MiB), and camera has no carveout.
  Inert until camera is brought up; decide the split then.
- IPA "ipa" interrupt: stock says GIC SPI 654, upstream sm8350 says 655 (sc7280 says
  654). Unpatched here: the OnePlus 9 Pro Arch port (LuCiLuna/oneplus9pro-arch,
  SM8350, mainline 7.3, 145 patches) has working LTE data and VoLTE with upstream's
  655 and no IRQ patch. If IPA probes but never interrupts, 654 is the first thing
  to try, as a `sm8350.dtsi` patch.
- Userspace stack chosen (as in the OnePlus 9 Pro port and Nura): `rmtfs -r -P -s`
  serving modemst1/modemst2/fsc/fsg by partlabel (read-only NV: the modem's writes
  stay in RAM, the partitions are never written from Linux, which keeps the
  never-write-to-modemst rule), rmtfs itself starting the mpss remoteproc; `qrtr-ns`;
  `tqftpserv` (the modem's `modem_pr/` carrier configs); then ModemManager with a
  `b2q-sim-provision` oneshot opening the USIM as primary GW provisioning session
  before ModemManager probes. No QTEE/license daemons needed on SM8350.
- Added `userspace/rootfs/usr/lib/b2q/sim-provision` (qmicli over qrtr://0),
  `b2q-sim-provision.service`, `ModemManager.service.d/b2q-sim.conf`.

## Cellular: modem up, IMEI reads, MM waits for a live SIM (2026-11-07)

Kernel #52, no kernel or DT change. Everything below ran on the phone over ssh.

- Firmware pushed (`modem.mbn`, `ipa_fws.mbn`, hashes verified). On 7.3.1 the IPA
  driver loads `ipa_fws.mbn` at probe, not at setup: its boot-time probe had failed
  with -2, so after the push `modprobe -r ipa; modprobe ipa` gave
  "IPA driver setup completed successfully" (GSI fw via PAS id 15, the same id as
  stock's separate `qcom,ipa_fws` node).
- `echo start > /sys/class/remoteproc/remoteproc1/state` (mpss, auto_boot false):
  PAS auth of the Samsung-signed modem.mbn passed on the first try. "Booting fw
  image ... size 88596620", "received modem running event", "remote processor
  modem is now up". It stays up even without rmtfs: no wdog, no fatal.
- Deployed `rmtfs -r -P -s` + `tqftpserv` (static aarch64 builds, pins and build
  recipe in `out/cellfw/MANIFEST.txt`, reproducible via `tools/build-cellfw.sh`).
  rmtfs serves modemst1/modemst2/fsc/fsg by partlabel (all four labels exist),
  NV read-only: the modem's writes stay in RAM. `echo stop` to the remoteproc
  logs "timeout waiting for shutdown ack" (mainline hardcodes 5 s, stock's
  proxy-timeout is 10 s) but completes the stop; rmtfs then boots the modem again.
- tqftpserv fielded real requests during modem boot: RRQ `/readwrite/ota_firewall/
  ruleset`, rejected, non-fatal (stock answers that one from persist; the
  Fairphone 5 logs the same). Korean carrier configs extracted to
  `qcom/sm8350/Samsung/b2q/modem_pr/` (oem_sw.txt lists KT/LGU/SKT, LGU = the LUC
  carrier of this phone), `lahaina/qdsp6m.qdb` next to it for ramdumps.
- `qrtr-lookup` shows the full QMI suite registered over QRTR: DMS, NAS, WDS, UIM,
  voice, messaging, AT, CAT, IPA control, IMS QMI Priv, PDC and EFS services.
  No userspace qrtr-ns: 7.3.1 has the in-kernel nameserver (`qrtr-y :=
  af_qrtr.o ns.o`), and `/proc/net/qrtr` does not exist in mainline at all (no
  `proc_create` in `net/qrtr/`), so registration is checked with qrtr-lookup.
- IMEI reads via `qmicli --dms-get-ids`: <IMEI>, IMEI SV 1. The modem's
  NV is intact and served through rmtfs.
- SIM: with an old, likely dead SIM the UIM reports `error: no-atr-received (3)`.
  ModemManager 1.24.2 creates the qcom-soc modem but init fails: "Couldn't check
  unlock status: QMI operation failed: GW primary session index unknown", state
  -> failed. That is the exact failure b2q-sim-provision exists for; it needs a
  live USIM to answer. With no answering card the script burns its full bound
  (90 iterations, each one qmicli + 2 s, so up to ~6 minutes, not the 3 the
  comment claimed).
- Crash forensics from the loop that followed (before the reboot), saved under
  `evidence/device/20261107-cellular-crashloop/` (dmesg, journal, rmtfs -v):
  the modem DOG-crashed ("stalled initialization") about 65 s after every boot,
  with or without SIM, while the rmtfs -v trace showed a complete EFS sync
  every cycle (modem_fs1/modem_fs2/modem_fsg open, reads, a 5120 B write,
  alloc of the 2.5 MiB window at 0x9b800000). One boot in that session ran
  444 s without a crash; the rest stalled. Not fully explained.

## Cellular: LG U+ LTE data works (2026-11-07)

After a phone reboot (allowed: after a crash) with the active SIM (the iPhone
13 mini's line, LG U+) in the tray:

- The first modem boot after power-on stalls once (DOG at 65 s, the same
  pattern the Galaxy Book Go SM8350 port describes as "the second try works")
  and the crash recovery boots stable. All later state was functional. The
  power-on stall still needs root-causing; the DOG fires before any QMI client
  can be created, so it cannot be poked from the AP.
- Registered: home, KOR LG Uplus (45006), access tech lte + 5gnr, 70 % signal.
  SIM USIM application ready, PIN1 disabled; the modem opened the primary GW
  provisioning session itself (b2q-sim-provision found it already open and
  finished in one call). Own number 010XXXXXXXX. Modem firmware
  MPSS.HI.4.3.3.c3-00050-LC_ALL_PACK-1.7516.231.18183.309 [Jan 21 2026].
  The initial EPS bearer is the IMS one (APN "IMS", IPv6): the network
  provisioned IMS at attach.
- Data bearer: `mmcli --simple-connect apn=internet.lguplus.co.kr` first failed
  with netlink EOPNOTSUPP: ModemManager multiplexes the bearer over rmnet, and
  the minimal kernel config had CONFIG_ETHERNET off, which hides the whole
  Qualcomm ethernet menu including CONFIG_RMNET. Fixed in configs/b2q.fragment
  (ETHERNET=y, NET_VENDOR_QUALCOMM=y, RMNET=m; same as the working OnePlus 9
  config), module-only install over ssh, no reboot.
- Connected: bearer 1 multiplexed on qmapmux0.0@rmnet_ipa0, IPv6
  2001:db8:1:1::/64 (the addresses here are documentation ones in place of the line's),
  gateway 2001:db8:1:1::2,
  DNS 2001:4430:4:617::1, MTU 1400. ping -6 -I qmapmux0.0
  2001:4860:4860::8888: 3/3, 80-221 ms. Cellular data works.
- The LTE attach gave IPv6 only; IPv4 data untested.
- Voice/VoLTE (IMS stack), SMS, plasma-dialer and spacebar: not done yet.

## Cellular: DT split fix installed; IMS is the remaining gate (2026-11-07)

- The 0x9b800000 wart is fixed: b2q.dts now deletes the dtsi rmtfs_mem and
  defines its own at 0x9ae00000/0x280000 (the free gap between pil_modem_mem
  and the camera carveout, unreserved in both trees), so stock's camera region
  keeps its address and size. Patch 0001 regenerated from the tree file
  (applytest: all patches apply, every touched file byte-identical), image
  installed over ssh, rebooted. rmtfs alloc now comes from 0x9ae00000 and the
  modem registers normally off it.
- SMS: ModemManager messaging works (storages sm/me) but `--send` times out
  (mmcli 1.24 syntax: `-s /org/.../SMS/N --send`, and `--messaging-send-sms`
  no longer exists; `-m 0 --list-bearers` also gone). The cause is IMS: the
  modem is PS-only (`Voice support: 'no'`, `cs-domain-not-available`
  rejection is expected on LG U+), and SMS on U+ is IMS-only, per Noa.
- 81voltd (the IMS DCM server, QMI service 770, commit a7794dd from
  gitlab.nura.eco/modem/81voltd) is built as an Arch package on the phone
  itself (makepkg as user `build`, deps from pacman incl. a dynamic qrtr
  package at 29e36ae that replaced the two static qrtr tools; rmtfs and
  tqftpserv stay the static cross-builds). Service drop-ins on the phone:
  order.conf (Before=ModemManager.service) and debug.conf
  (G_MESSAGES_DEBUG=all) — NOT yet in the repo's userspace/rootfs, copy them
  in when finishing this. 81voltd registers service 770 and finds MM's modem,
  but the modem never sends the IMSD 0x20 request: Samsung's firmware does
  not use the DCM path the way OnePlus's does.
- PDC (service 36) is correct: software config "LUC" (LG U+) Active, "SKC"/
  "KTC" inactive, platform "SS-LA-Lahaina" Active. The carrier profile is
  not the blocker.
- The modem's IMS application is not up: qmicli client creation on `ims`
  and `imsa` services fails with QMI 'Internal' (with or without
  --ims-bind=N; the bind takes an integer, unlike the help text suggests).
  Service 77 ("IMS QMI Priv") is registered but also refuses. Per the
  OpenIMSD write-up (openimsd.de/08-how-volte-is-working.html) the flow is:
  PDC profile -> IMS Settings service ("basic enable VoLTE") -> modem opens
  IMS PDN -> DCM request -> SIP register. We are stuck before the IMS settings
  step; something must start/enable the modem's IMS app (on stock Android,
  Samsung's vendor IMS daemon does this, likely via the Samsung-specific
  QMI services in our list: 1067, 5004, plus unknowns 227/232/68/73/74/78).
- Modem time is NOT the gate: the raw device counter reads 2017 but the sync
  fields are current (2026-11-07, set by ModemManager), and NAS network time
  is right.
- OpenIMSD (gitlab.postmarketos.org/modem/openimsd) is the working open IMS
  enabler (Nura v26.06 ships VoLTE on OnePlus 6 out of the box), but its repo
  needs auth from here; its PDC+IMS-settings approach is the next lead. Also
  relevant: Biktorgj/imsd, "hyphae", XDA thread "Qualcomm IMS/VoLTE
  configuration demystify" (IMS config lives in modem EFS).
- Crash behaviour, now with clean data: after every power-on the modem's
  first boot stalls (DOG at 65 s) and the recovery boot is stable and fully
  functional. Mid-run `systemctl restart rmtfs` (graceful modem stop)
  reproducibly breaks it again: the next boots stall with only ~9 QRTR
  services registered, followed by DOG crashes and instant non-DOG crashes.
  Never restart rmtfs while the modem is up; reboot the phone instead.
  Root-causing this is still open (next patch number 0017 if it needs one).
- IPv4: refused by the network ('CallFailed' on the IPv4 half of ipv4v6);
  this SIM's data is IPv6-only. An explicit ip-type=ipv4 connect SIGABRT-crashed
  ModemManager (coredump present in coredumpctl); workaround: only request
  ipv4v6.

## Cellular: SMS over IMS, IPv4 findings (2026-11-07)

- IPv4 on this SIM is refused by the network: during the ipv4v6 connect MM logs
  "couldn't start IPv4 network: QMI protocol error (14): 'CallFailed'" at bearer
  start; the session is IPv6-only (2001:db8:1:1::/64). An explicit
  `--simple-connect ip-type=ipv4` then crashed ModemManager itself: SIGABRT,
  coredump present (coredumpctl, /usr/bin/ModemManager at 15:15:51). systemd
  restarted MM, the modem re-probed cleanly, NRestarts=1. Workaround until the
  MM bug is understood: only request ip-type=ipv4v6.
- Next: the active SIM, then restart the modem services; expect sim-provision to
  open the primary GW session and MM to initialize the modem.

## Cellular: IMS bring-up day (2026-11-07, openimsd stack + modem RE)

- OpenIMSD is public, no auth needed: gitlab.postmarketos.org 308-redirects to
  gitlab.nura.eco, and modem/openimsd is a public group (not a repo). Cloned
  qcom-imsd (fd15814), openimsd C daemon (3873d86), qcom-baseband-profile-manager,
  libqmi fork (b683efa, has IMS Set 0x8F), 81voltd reference.
- Built and installed on phone (user build, makepkg): python-gobject,
  python-statemachine + deps (pydot, construct, gsm0338, hatchling, graphviz,
  pyparsing, six), python-pyosmocom, libqmi fork 1.39.0 (provides=libqmi,
  -Udd over stock; MM keeps working, same .so.5), qcom-imsd 0.0.1.
- qcom-imsd needed one phone-side fix: statemachine 3.x reserves self._config,
  clobbering qcom-imsd's Config; renamed to self._ims_config in installed
  main.py (lines 137/235). Upstream targets statemachine 2.x.
- qcom-imsd runs through PDC/IMSA open then fails: modem returns "Service not
  supported" on IMSA (33) alloc at CTL level. qrtr-lookup confirms: only IMS QMI
  Priv (77) + IMS data (770, our 81voltd) published; no ims (18)/imsa (33).
- Service ID survey: 227=QMI FOX, 232=QMI GAS (standard, not Samsung);
  68/73/74/78/1067/5004 unidentified, no public docs. Modem blob has zero hits
  for 1067/5004. Service 77 = internal IMSPrivServiceAdapter, no client API.
- mcfg_tools unpack of LUC MBN (17,572 B): ZERO IMS items (no
  nv/item_files/ims/*, no voice_domain_pref, no Data_Profiles, no IMS APN).
  Only banner + carrier_policy.xml (5,025 B, no volte stanzas) + 3 RRC NVs.
  Control: China Telecom VoLTE MBN unpacks fine with voice_domain_pref (07 03),
  nr5g_full_voice_support (07 01), nas_srvcc_support, Data_Profiles.
  LGU IMS comes from elsewhere (modem defaults + Samsung userspace), not MBN.
- Modem blob RE (modem.bin FAT, strings): IMS task compiled in (imstask_init),
  gate is post_start_init reading /nv/item_files/ims/IMS_enable +
  THIRD_PARTY_NV + MCFG/policyman volte_enabled; CM self-heals missing EFS
  (put EFS with %d). Samsung AP path is SIPC_SamsungIMS_CMDHandler /
  oemapi_ims IMS_REG_SET, no QRTR/QMI 18/33. Quectel confirms LG U+ MBN lacks
  IMS-SMS; U+ is LTE-only, SMS is IMS-only (no SGs/CSFB). Voice dial (0x20)
  exists but routes over IMS internally, useless without registration.
- qmicli PDC load crash fixed (use-after-free: g_free on
  g_mapped_file_get_contents in load_config_file_from_string; patched via
  PKGBUILD prepare(), pkgrel 2). Stock LUC MBN load then fails InvalidQosId
  (already active?), custom LGU+IMS MBN (LUC + 3 CT NV items, pack_mcfg,
  round-trip verified) fails AuthenticationFailed (unsigned). PDC path dead
  without Samsung signing.
- WDS side: set lte_ims profile APN to ims (was empty) + PDP IPv6 (was
  ipv4v6); persists in modem EFS. Chained WDS bind-mux + set-ip-family +
  start-network apn=ims via Python GIR returns START OK but creates no netdev
  (modem swallows it, no app behind it). 81voltd still sees only type-6
  hellos, never DCM 0x20.
- Next: reboot phone so modem re-reads Data_Profiles with the fixed IMS APN;
  check for ims/imsa services or DCM 0x20 after boot.

## Cellular: post-reboot, all write paths exhausted (2026-11-07)

- Rebooted phone (up ~60s, modem registered 17:58). No change: still no
  ims/imsa, 81voltd hellos only. WDS profile change REVERTED (rmtfs read-only:
  modem EFS writes live in RAM only). Re-applied? No: pointless without the
  NV gate; profile alone never starts the app.
- QMI EFS (service 21) is stubbed in this firmware: MFS 0x20/0x21 fail
  generically, no EFS message strings/handlers in blob (only RMTFS + SFS
  named; fs_qmi_service compiled in but exports nothing). qmi_efs.py
  (CaullenOmdahl/blackshark-klein) connects but PUT/GET both fail. No EFS
  write path exists.
- Ghidra RE set up and working: modem.mbn squashed via tools/pil-squash.py
  (88,596,620 B), imported headless as Hexagon ELF (base c0800000, 36k funcs,
  134k syms), MCP server live on :8089. IMS strings located (c3cf7867/
  c3cf7819) but no symbols/xrefs (stripped statics, Hexagon ##imm not
  byte-searchable). Project in /tmp (rebuildable, not committed).
- BLOCKED, needs Noa. Every AP-side path to the modem's IMS gate
  (IMS_enable EFS + MCFG volte evaluation) is closed: EFS stubbed, PDC
  unsigned rejected + packer lossy, rmtfs read-only by rule, WDS wrong
  layer, SIPC no driver, no Android for stock APK. Options needing her call:
  (a) PDC-activate CT VoLTE MBN (signed, has IMS items; wrong carrier,
  reversible via LUC re-activate, may need reboot, may break attach);
  (b) direct modemst write (rule violation); (c) Samsung SIPC driver
  (major project); (d) shelve IMS, do call-audio + plasma-dialer + rootfs.
- Phone went off-network after (no ping, no ssh: suspended/off). Data was
  working (ping6 google OK) before drop. Awaiting phone + Noa.

## Cellular: Noa approved rmtfs writable, WDS IMS PDN breakthrough (2026-11-07)

- rmtfs review (source + agent): `-r` = RAM shadow, no persistence; without
  `-r` every modem write goes straight to backing store + fdatasync. Sector
  proxy, no filename awareness. No on-demand sync exists.
- sdf (holds fsg) is hardware write-protected ("Write Protect is on"); fsg
  unwritable from AP. modemst1/2 (sda1/2), fsc (sda3) writable.
- First writable attempt (direct partitions, -P -s no -r) CRASHED modem:
  rmtfs O_RDWR on fsg fails EROFS, modem fatal on first read, DOG loop x4+.
  Reverted to -r, rebooted stable.
- File-backed writable rmtfs now live (phone-local override, NOT committed):
  /root/nv-live/ holds partition copies, rmtfs `-o /root/nv-live -s` (no -P,
  no -r). Modem boots stable, registered, data works. Partitions untouched.
- Writable-boot diff: modem wrote 2.6 MB churn to fs2 copy. Samsung EFS format
  is proprietary (IMGEFS1R/2Q/G headers, no EFSSuper, no plaintext paths):
  efs2_extractor finds nothing. Offline EFS parsing blocked.
- WDS IMS PDN WORKS (control plane): fresh 3gpp profile 4 (apn=ims, IPv6),
  bind mux 3, start-network returns handle + IPv6 addr + gateway + DNS +
  MTU 1400 + P-CSCF-via-PCO flag. qmapmux0.3 created, IP assigned.
- BUT data plane is dead: rx=0 tx=99, gateway/DNS ping fail, TCP 53/5060
  timeout, UDP DNS timeout. Modem will not forward IMS traffic without its
  IMS app mapping the bearer. Userspace SIP blocked at L3.
- MM fragility: --simple-disconnect SIGSEGVs MM (coredump); it restarts and
  reprobes in ~30s. Do not touch bearers casually.
- Noa: CT MBN PDC load attempted (signed, 34 KB). Upload hung 4 min, modem
  crash-looped (IPA assert + DOG x7). Reboot recovered clean (LUC active,
  no partial config). PDC load of foreign MBN is dangerous; not retrying
  without understanding.
- Platform result: NOBODY has Samsung SM8350 IMS on mainline. OnePlus 9 Pro
  works because its modem publishes ims/imsa (modem-initiated DCM). Fold3/q2q
  works on AOSP via userspace SIP (PhhIms/krazey/ims) over RIL IMS PDN.
  Our modem publishes neither; our IMS PDN has no data path.
- ISIM logical channel opens fine (ch 3) but app stays 'detected'; no effect.
- efs_inject.py committed (tools/, untested: needs EFS format + live image).
  Ghidra MCP live (:8089), modem analyzed (36k funcs); CM gate function still
  unlocated (stripped, no xrefs to IMS strings).

## Cellular: Phase 0 MM-identical IMS setup confirms modem gate (2026-11-07)

- PJSIP bg agent (bg-22-2dc082a4) died with the old session: source extracted
  only, never compiled. Restarted `makepkg -s` as build ~22:30 (build-2230.log);
  compiling clean (pjlib -> pjnath -> pjsip link stage). NOT installed yet.
- b2q-imsd stub committed (ae87730, userspace/imsd/src/imsd.c). HEAD now ahead 51.
- Phone rebooted ~21:37 (uptime 52m at 22:29). ims_bearer.py re-ran 21:44+21:47,
  holding WDS handles, but NO qmapmux0.3 after reboot: the holder never creates
  the kernel netdev, it only does bind-mux + start-network. Pre-reboot rx=0
  reading was without... now re-tested properly with netdev present.
- MM working setup captured from 22:16 debug logs (no disconnect needed):
  mux-rmnet / raw-ip / qmapv5 UL+DL, dynamic mux ID 1, RMNET link flags
  ingress-map-cksumv5 + egress-map-cksumv5 (MM's claim; `ip -d` shows only
  INGRESS_DEAGGREGATION even on the working qmapmux0.0), separate IPv4/IPv6
  WDS clients, Bind Mux + Start Network + Get Current Settings, MTU 1400.
- Fresh-client WDS GetCurrentSettings fails OutOfCall (15): settings only come
  from the client that started the network. Reused the holder's logged values
  (same boot, holder PID alive): addr 2001:db8:2:2::1/64,
  gw 2001:db8:2:2::2, dns 2001:4430:5:601:2::1 +
  2001:4430:4:601::1, MTU 1400.
- Created qmapmux0.3 (mux 3, EMBEDDED/1 bound by holder, MTU 1400, kernel flags
  identical to MM's link), assigned addr, default route via gw. L3 test:
  gateway ping 6/6 lost across two runs, UDP DNS query 5 s timeout.
  TX 16 pkts out, RX 0. Modem-side gate CONFIRMED with MM-identical setup.
  `ip link set ... type rmnet` flag tweak refused (needs mux_id restated);
  irrelevant since working link reports identical flags.
- Per plan Phase 0 step 5: SIP work pauses for L3. qmapmux0.3 + WDS holder left
  up for later; harmless, MM-visible as before.
- NEW MM fragility: count_bearers assertion `(max >= ctx.count)` crashed MM
  twice 22:15-22:16 (PIDs 1672->2292->2745->2938); a bearer2 appeared 21:46.
  Do NOT create MM-managed second bearers casually; manual WDS path only.
