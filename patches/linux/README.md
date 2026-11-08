# Linux patches

Numbered series against `LINUX_VERSION` in `sources.lock`, applied in order by
`tools/fetch-kernel.sh --apply`. Every patch is `git format-patch` style, with a `Subject:` and a
body explaining why, so the series can be posted as-is.

Nothing here yet: the scaffold lands before the first bring-up patch. Planned shape, in the order
they are expected to be needed:

| # | patch | notes |
|---|---|---|
| 0001 | `arm64: dts: qcom: add Samsung Galaxy Z Flip3 5G (b2q)` | Based on Alicja Michalska's Nura tree for the F711B, corrected for board-id 08 from the stock DT. Reaches userspace; ACM shell over USB |
| 0002 | `dt-bindings: display: panel: document Synaptics SW43404` | Family sibling of the in-tree `panel-lg-sw43408.c` |
| 0003 | `drm/panel: add Synaptics SW43404` | Init sequence and timings lifted from the stock `dtbo`; start at `fhd60ns` (60 Hz) |
| 0004 | `drm/msm: support 2-encoder DSC on the DSI output` | Only if the DPU side needs it; the panel uses two DSC encoders |
| 0005 | `dt-bindings`/`input: Synaptics TDDI touch` | RMI4 over SPI/I2C; the display half and the touch half are the same chip |
| 0006 | `arm64: dts: qcom: b2q: enable display and touch` | Panel, backlight, touch supplies |
| 0007 | `arm64: dts: qcom: b2q: CPU/GPU OPP tables` | From the stock DT; without them the phone runs one frequency and hot |
| 0008 | `arm64: dts: qcom: b2q: charger and fuel gauge` | The gate for running untethered |

The ordering is not a promise: M1 needs only 0001, and it may be split (memory map and reserved
memory first) if the whole board DTS does not boot at once.
