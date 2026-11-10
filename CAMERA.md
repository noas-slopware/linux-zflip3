# Cameras (Galaxy Z Flip3, SM-F711N)

Status, 2026-11-10: **the rear ultrawide streams RAW10 on kernel #7.** IMX258 at 4208x3120,
30 fps, through CSIPHY2, CSID0 and VFE0 RDI0 (`/dev/video1`). The sensor's colour-bar
test pattern arrives exact (eight bars, full 10-bit range), so the lanes and the Bayer order
(BGGR) are right. The rear wide (IMX563) and the front (IMX374) have no driver yet, and there
is no ISP path (RDI only: raw Bayer, no debayer, 3A or autofocus).

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
  com.samsung.sensormodule.*.bin`, Chromatix parameter-parser format, not decoded yet) are
  the source for the IMX563 and IMX374 register sequences.
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

Config: `CONFIG_SM_CAMCC_8350=m`, `CONFIG_VIDEO_IMX258=m` (CAMSS and CCI were already `m`).

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

## Open

- CAMNOC QoS: stock programs it, CAMSS does not. The first captures at 30 fps showed no
  errors, but it is untested under load.
- IFE SMMU stream mask: stock 0x440 against sm8250's 0x400; no faults seen.
- IMX563 (wide) and IMX374 (front): new sensor drivers, register sequences from the CHI
  module binaries.
- Userspace: libcamera's simple pipeline handler with its software ISP is the likely path
  to a usable image.
