# The display

> **Provenance warning.** Everything on this page came from a decompile of Samsung's stock
> firmware device tree, relayed through a third party. It is plausible and internally
> consistent, but it is not our evidence yet. `tools/extract-firmware.sh` produces the real
> thing from the phone's own AP tar in M0; if the two disagree, ours wins and this page gets
> rewritten.

## What we expect

- 1080x2640 (`0x438` x `0xa50`), 6.7in foldable AMOLED, DSI0, command mode.
- DDIC: **Synaptics `sw43404`**, a TDDI part: display driver and touch controller in one
  chip. The panel is BOE's.
- Four timing sets: `fhd120hs` (120 Hz), `fhd96hs`, `fhd60hs`, `fhd60ns` (60 Hz).
- Every one of them uses **DSC with two encoders**: slice `0x21c` x `0x28`, 8 bits per
  component, 8 bits per pixel, block prediction on. There is no non-DSC mode to fall back on.
- The full `mdss-dsi-on-command` init sequence is present in the overlay device tree.
- Cover display: 1.9in 260x512 on DSI1.

## Why this is tractable

- **Mainline already has the SoC side.** `dpu_7_0_sm8350.h` exists, and `sm8350.dtsi` has
  `mdss`, `mdss_dsi0`, `mdss_dsi1`, both 7nm DSI PHYs and the DP controller.
- **A sibling driver exists.** `drivers/gpu/drm/panel/panel-lg-sw43408.c` is the same
  Synaptics family, DSI, DSC, and uses `drm_dsc_helper`. The panel half of the work is
  adapting that: init sequence, timings, supplies, backlight.
- The init sequence and timings come from the stock DT rather than from reverse engineering
  a binary, which is the difference between days and weeks.

## The unknown: two DSC encoders

Mainline's DSC path is usually exercised with one encoder. This panel splits the frame
across two, so the DPU/DSI side may need work beyond the panel driver (`patches/linux/0004`
is reserved for it). Start at `fhd60ns` (60 Hz) to keep the first bring-up simple, and
only then go to 120 Hz.

## Order of attack

1. **Framebuffer console.** `simple-framebuffer` over the splash region at `0xe1000000`,
   size `0x2300000` (from the stock DT's `cont_splash_region`). LK leaves the panel scanning
   out of that buffer, so this can give a working console with no panel driver at all. Cheap
   experiment, sometimes enough to debug the rest from.
2. **Panel driver at 60 Hz.** `panel-synaptics-sw43404.c`. Verify the DDIC answers on DSI
   before worrying about pixels.
3. **DPU/DSC.** Wire the panel to `mdss_dsi0`, add the DSC pair support if needed.
4. **Touch.** TDDI means a separate RMI4 channel over SPI or I2C, not DSI. In-tree
   precedent: `panel-sony-td4353-jdi.c` (same family). Samsung's `sec_ts` wrapper is what
   the stock DT describes; a minimal driver that does the same is enough.
5. **Cover display** as a second panel on DSI1, once the main one is solid.

## What to check in M0

From our own dump, not from this page:

- the panel node's `qcom,mdss-dsi-panel-name`, and whether more than one panel variant is
  present (Samsung ships several in one overlay)
- the exact `mdss-dsi-on-command` bytes
- the DSC properties per timing set
- the panel and backlight supplies: which PMIC regulator each one is
- the touch node's compatible and bus (`spi`/`i2c`), and its interrupt and reset GPIOs
