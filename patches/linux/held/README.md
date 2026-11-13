# Held patches

Not applied by `tools/build-kernel.sh --apply` (it only globs `patches/linux/NNNN-*.patch`).

- `0043-media-iris-register-the-encoder-on-SM8350-again.patch`: held back on 2026-11-10 at
  Noa's call. Any encode on SM8350 resets the SoC on the first input frame (see STATE.md), so
  `/dev/video1` stays unregistered (0021's SM8350 skip) until the encoder works.

## Not written yet: choosing the rear ultrawide sensor at boot (S5K3L6, 0137)

`0137` adds the S5K3L6 driver, but the board DT still has only `camera@1a` (IMX258) on CCI1
master 0. The S5K3L6 sits at 0x2d on the same bus, behind the same rails (S2MPB02 L12/L4/L10),
MCLK1 (gpio101), reset (gpio106) and pinctrl state (`cam_uw_default`). Why a second node cannot
simply be added, and what each way out costs:

- CAMSS registers its cameras only when every sensor in its graph has bound
  (`camss_subdev_notifier_complete()`), so a node for the absent sensor would take all three
  cameras away, on every unit.
- Two enabled nodes also claim the same pins and reset GPIO; the two sensor modules load in
  parallel, so the IMX258 can lose that race (-EBUSY, not a deferral) on a unit that has it.
- The mainline way for second-source parts is `fail-needs-probe` nodes and a board prober
  (`drivers/i2c/i2c-core-of-prober.c`, as `chromeos_of_hw_prober` does for touchscreens). Its
  simple helpers power one regulator and one GPIO; this slot needs three rails, MCLK at
  19.2 MHz and the `cam_uw_default` pin state before either sensor answers, so the prober
  needs its own enable step that takes those from the sensor node, and identifies by chip ID
  (IMX258 0x0016 = 0x0258, S5K3L6 0x0000 = 0x30c6) rather than a bare address ACK. CAMSS then
  has to skip endpoints whose sensor is disabled and defer while one is still
  `fail-needs-probe`, and the prober has to fail safe: any error enables `camera@1a`, so a
  prober fault never costs the IMX258 units their cameras.

All three pieces change the path the IMX258 comes up through, and there is no S5K3L6 unit to
try them on (nor proof that a retail Korean F711N has one), so they wait for a boot on the
phone that shows all three cameras still enumerate.
