# Cameras (Galaxy Z Flip3, SM-F711N)

Status, 2026-11-10: **all three cameras stream RAW10 on kernel #7, and libcamera turns
them into pictures.** Every sensor's colour-bar test pattern arrives exact (eight bars, full
10-bit range), so the lanes and Bayer orders are right:

| camera | sensor | mode | PHY | Bayer |
|---|---|---|---|---|
| rear wide | IMX563 | 4000x3000, 30 fps | CSIPHY0, C-PHY, 3 trios, 1896 Msps | RGGB |
| rear ultrawide | IMX258 | 4208x3120, 30 fps | CSIPHY2, D-PHY, 4 lanes, 633.6 MHz | BGGR |
| front | IMX374 | full resolution, 30 fps | CSIPHY3, D-PHY, 4 lanes | GRBG |

CAMSS runs the RDI path only (raw Bayer). Debayering, auto exposure and white balance come
from libcamera 0.7.2's simple pipeline with its software ISP (`userspace/libcamera`, with
IMX374 and IMX563 sensor helpers). The wide camera has no autofocus or OIS yet, so it is
fixed-focus and soft up close.

## Hardware (stock dtbo entry 3, board id 08: `ro.boot.revision = 8`)

| camera | sensor | bus | CSIPHY | MCLK | reset | rails (S2MPB02) |
|---|---|---|---|---|---|---|
| rear wide | Sony IMX563 | CCI0 master 0 | 0 | gpio100, 19.2 MHz | gpio136 | see survey |
| rear ultrawide | Sony IMX258 (this unit) | CCI1 master 0, 0x1a | 2 | gpio101, 19.2 MHz | gpio106 | L4 1.2 V vdig, L10 1.8 V vio, L12 2.7 V vana |
| front | Sony IMX374 | CCI0 master 1 | 3 | gpio102, 24 MHz | gpio202 | see survey |

- Sensor models: Samsung's `techpack/camera/drivers/Makefile` for B2Q (wide `imx563_b2`,
  ultrawide `imx258_b2`, front `imx374`). Stock's vendor partition also ships a Samsung
  S5K3L6 module for the ultrawide slot; this unit has the IMX258 (the driver's chip-ID check
  passed at 0x1a).
- The stock DT carries no sensor I2C address or lane count: stock's userspace sends them in
  probe packets. The per-slot CHI module binaries (`/vendor/lib/camera/
  com.samsung.sensormodule.*.bin`, CamX Chromatix parameter-parser format) hold them, and
  `tools/chromatix-dump.py` decodes their addresses, lane setup, link rates and register
  sequences: wide IMX563 at CCI0 master 0 0x10, front IMX374 at CCI0 master 1 0x1a.
- CSIPHY supplies: L5B 0.88 V and L6B 1.2 V. Stock CSID/VFE are the 580 generation, which
  Samsung's own driver binds to the 480 register tables; CSIPHY is v1.2.3.

Full survey with file:line citations: `scratch/camera/stock-topology.md` and
`scratch/camera/camss-580-vs-mainline.md`.

## Kernel patches

| patch | what |
|---|---|
| 0056 | `camcc-sm8350`: the camera clock controller, ported from downstream `camcc-lahaina` (v2 PLL2 config) |
| 0057 | CAMSS: SM8350 resources, the CSIPHY v1.2.3 lane table, three full IFEs plus two IFE-lite |
| 0058 | `sm8350.dtsi`: CAMSS and CCI0/CCI1 nodes |
| 0059, 0060 | upstream (Muzaffer Kadir, linux-media v2): IMX258 waits 0.4 ms after power-on, and drives `reset-gpios` (mainline documents it but never used it; XCLR on this board would keep the sensor in reset) |
| 0061 | b2q: the ultrawide (rails, pins, CCI1, CSIPHY2) |
| 0062, 0063 | IMX374 driver (register sequences from the CHI module) and the front camera DT |
| 0064-0072 | upstream C-PHY support for CAMSS (v9 series, patchwork series 28525) |
| 0073 | the SM8350 C-PHY init sequence for CSIPHY v1.2.3 |
| 0074 | CSID gen2: CSI-2 RX and RDI interrupt status in the debug log |
| 0075 | CAMNOC AXI clock sized from bandwidth like stock's CPAS (max(bw x 1.2, 3 GB/s) / 32 bytes): it sat at 19.2 MHz before |
| 0076, 0077 | IMX563 driver (C-PHY; LINK_FREQ is half the symbol rate) and the rear wide DT |
| 0078 | rotation and orientation for all three (wide 90, front 270, ultrawide 90), which libcamera reads |
| 0079 | CSID stops setting the IFE core clock to its lowest rate, which made the VFE fail its clock check with EBUSY |

Config: `CONFIG_SM_CAMCC_8350=m`, `CONFIG_VIDEO_IMX258=m`, `CONFIG_VIDEO_IMX374=m`,
`CONFIG_VIDEO_IMX563=m` (CAMSS and CCI were already `m`).

## Capture

```sh
media-ctl -d /dev/media0 -l '"msm_csiphy2":1->"msm_csid0":0[1],"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
F=SBGGR10_1X10/4208x3120
media-ctl -d /dev/media0 -V "\"imx258 12-001a\":0[fmt:$F field:none],\"msm_csiphy2\":0[fmt:$F],\"msm_csid0\":0[fmt:$F],\"msm_vfe0_rdi0\":0[fmt:$F]"
v4l2-ctl -d /dev/video1 --set-fmt-video=width=4208,height=3120,pixelformat=pBAA
v4l2-ctl -d /dev/video1 --stream-mmap=4 --stream-count=5 --stream-to=frames.raw
```

Exposure and gain are V4L2 controls on the sensor subdev (`exposure` up to 3142 lines at the
default frame length, `analogue_gain` 0..480). With no 3A the defaults give a dark frame.

Through libcamera: `cam -l` lists the three cameras with their location and rotation, and
`cam -c <n> --capture=10 --file=frame#.ppm` (or any libcamera/PipeWire app) gives debayered
pictures with auto exposure.

## Open

- CAMNOC QoS: stock programs it, CAMSS does not. The first captures at 30 fps showed no
  errors, but it is untested under load.
- IFE SMMU stream mask: stock 0x440 against sm8250's 0x400; no faults seen.
- Wide camera autofocus (2026-11-11, 0099/0100, libcamera 0.7.2-6): the AK7377 at CCI1
  master 1, 0x0c, through ak7375 (standby before active, as stock); libcamera's soft ISP Af
  scans it, convergence not yet seen in light (`STATE.md` header). OIS: the MCU on QUP SE2
  has no driver.
- `cam` at full resolution and 1080p works on all three cameras since 0105 (384 MiB CMA).
- Autofocus speed (libcamera 0.7.2-9, 0017): the soft ISP measures every 4th frame and the
  IPU3-derived algorithm counted its settle time and fine window as if every frame: the lens
  never settled within 10 s. Now the settle time is in frames and the fine scan covers one
  coarse step either side of the coarse peak in eighths; on the phone it was stable at step 405
  about 2 s after start (10 scan steps). Host model in the scratchpad's `afh/`.
- Calibration: no lens shading or AWB data from the module EEPROMs, and no libcamera tuning
  files; the ultrawide's crop and orientation are not yet compared against stock.
- The flash LED works on its own but is not tied into capture.
- Sensor delays for libcamera's helpers are estimates, not measured.
- The hardware ISP (the IFE pixel path) is not pursued (Noa, 2026-11-10). Upstream has two
  competing, unmerged approaches (Qualcomm's 45-patch series for SM8250/SA8775P/QCS8300 of
  2026-10-07, and Bryan O'Donoghue's extension of camss-vfe) and no libcamera pipeline
  handler for it.
