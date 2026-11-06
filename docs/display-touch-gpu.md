# Display, touch, GPU and USB (main screen)

State on 2026-11-06, kernel 7.3.1 with `patches/linux/0001`–`0007`. Facts and raw
captures are in `evidence/SM-F711N-m0.md`.

## USB without re-plugging

The USB-C D+/D- lines go through a switch in the MAX77705's Type-C block (I2C 0x25,
next to the PMIC at 0x66 on `i2c7`). Nothing in mainline sets it, so after a warm reboot
it stayed open and the gadget never connected until the cable was re-plugged.

- `0002`: the mainline MAX77705 core rejected this chip (PMICID1 0x15, rev 2, "MD15
  PASS2" in Samsung's driver); it now accepts it.
- `0003`: at probe the core masks and clears the Type-C block's interrupts and sends
  CONTROL1_WRITE `0x09` (D+/D- to USB) through the opcode mailbox; at shutdown it opens
  the switch again, like Samsung's driver.
- U-Boot `patches/u-boot/0010` does the same at bind time, so fastboot connects too.
- DT: the MAX77705 interrupt pad (PM8350C GPIO5) is sampled on VIN1 (`power-source =
  <1>`, as stock). On VIN0 it read low all the time and the IRQ storm got it disabled.

## GPU (Adreno 660)

- Runs headless next to the display: `msm.separate_gpu_kms=1` in `configs/cmdline`.
- Zap shader: Samsung-signed, `image/a660_zap.*` in NON-HLOS.bin from the BL tar.
  `tools/extract-qcom-firmware.sh BL_*.tar.md5` writes
  `out/firmware/usr/lib/firmware/qcom/sm8350/Samsung/b2q/a660_zap.mbn`
  (joined with `tools/pil-squash.py`). SQE/GMU firmware come from linux-firmware.
- `0004`: the first GPU probe at boot fails and is retried; the retry used to hit
  `-EBUSY` because the GMU's RSCC and PDC regions were mapped with devm on a device
  that never has a driver. Fixed by mapping them with plain ioremap.
- Check: Mesa reports `FD660`, OpenGL 4.6 / ES 3.2.

## Touch (STM FTS9CU80F, Samsung firmware)

- `i2c4` (QUP SE4) needs `gpi_dma0`, which was off; with it on, the controller answers
  at 0x49. Supplies: S2DOS05 LDO2 (vdd, 1.8 V) and LDO3 (avdd, 3.0 V); IRQ TLMM 23,
  level low.
- It runs Samsung's sec_ts command set, not ST's protocol, so it has its own driver
  (`0005`, `st,fts9cu80f`): reset, wait for READY, touch types finger/palm/wet,
  calibrate, scan only while open. Coordinates 0..4095 on both axes, no flips needed;
  palms report as `MT_TOOL_PALM`.
- Check: `evtest /dev/input/event3`.

## Display (S6E3FAC + AMF670BS01)

- 1080x2640 DSI command mode, DSC (two 540x40 slices, 8 bpc, 8 bpp), DSI0 4 lanes.
  Reset TLMM 22, TE TLMM 82 (`mdp_vsync`). Supplies: vdd3 S2DOS05 LDO1, vci LDO4,
  vddr BUCK.
- `0006`: panel driver with the stock fhd120hs sequences, decoded from the
  `B4_S6E3FAC_AMF670BS01` node in dtbo entry 3. Backlight is DCS 0x51, 0..2047.
- `0007`: backport of Dmitry Baryshkov's 7nm DSI PLL fix (digital top powered with the
  PLL bias); without it the PLL failed to lock at probe and clk warned.
- The panel, `i2c-gpio`, the sec MFD core and S2DOS05 are built in. As modules they
  held DRM back until ~10 s, with the bootloader pipeline already reset by MDSS.
  Built in, DRM takes over at ~1.5–1.9 s.

### Known, accepted or open

- About 42 ms of noise at takeover: the panel reset scrambles its frame memory and
  display on comes before the first frame (traced: display on 1.809 s, first
  `pp_tx_done` 1.851 s). Accepted. Skipping the reset on the handed-over panel made
  the screen garbled for good; do not try that again.
- TE (vblank) runs at 60 Hz although the 120 Hz init is sent (TE_FRAME_SEL
  `61 00 01`); the DPU side is correct (19.2 MHz vsync clock, external TE connected).
  Open: Samsung's VRR/LFD registers.
- Cover screen and its touch are not brought up.
