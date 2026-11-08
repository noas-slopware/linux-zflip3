# Samsung S2ASL01 battery current limiter — mainline port

`0011-s2asl01-limiter.patch` adds a mainline driver for the two S2ASL01
current limiters in the Galaxy Z Flip3 (SM-F711N, `b2q`), one per battery
cell, on i2c1 at 0x38 (main) and 0x39 (sub).

Everything register-level is ported from Samsung's vendor driver:

- `.cache/samsung/kernel/drivers/battery/limiter/s2asl01_limiter/s2asl01_limiter.c` (cited as `c:NNN`)
- `.cache/samsung/kernel/drivers/battery/limiter/s2asl01_limiter/s2asl01_limiter.h` (cited as `h:NNN`)
- `.cache/samsung/kernel/drivers/battery/limiter/s2asl01_limiter/s2asl01_limiter.dtsi` (the driver's own DT defaults)
- `evidence/raw/dtbo/entry.3.dts` — the decompiled stock DTBO: limiters at
  lines 9280-9315 (fragments @77/@78), pin states at 9167-9270 (fragments
  @72-@76), `sec-dual-battery` at 955-975, `sec_battery` at 28-260.

## 1. What the hardware does

One S2ASL01 sits in series with one cell. It programs a fast charge current
limit, a trickle charge limit, a discharge limit, an end-of-charge (EOC)
voltage and current, and can gate the cell with external enable pins. It
also carries a four-channel power meter (input voltage, cell voltage, charge
current, discharge current) and a health comparator on top of it.

The stock DT writes nothing to the limiter nodes beyond address, cell type
and GPIOs, so every limit and voltage below is the vendor driver's built-in
default and is what a stock phone runs with.

## 2. Register map

From `h:29-62`; the driver uses the same addresses.

| Addr | Name | Use |
|---|---|---|
| 0x00 | CORE_INT1 | core interrupt status 1 |
| 0x01 | CORE_INT2 | core interrupt status 2 |
| 0x02 | PM_INT | power meter interrupt status |
| 0x03 | CORE_INT1M | core interrupt mask 1 |
| 0x04 | CORE_INT2M | core interrupt mask 2 |
| 0x05 | PM_INTM | power meter interrupt mask |
| 0x06 | CORE_STATUS1 | status |
| 0x07/0x08 | VAL1/VAL2_VCHG | input voltage, 12 bit |
| 0x09/0x0a | VAL1/VAL2_VBAT | cell voltage, 12 bit |
| 0x0b/0x0c | VAL1/VAL2_ICHG | charge current, 12 bit |
| 0x0d/0x0e | VAL1/VAL2_IDISCHG | discharge current, 12 bit |
| 0x0f | CORE_CTRL1 | bit 0 EOC on, bit 1 restart (recharge) |
| 0x10 | CORE_CTRL2 | bit 0 sub power-off mode |
| 0x11 | CORE_CTRL3 | bits 1:0 charge mode, 3:2 discharge mode, 6 supplement, 7 INOK |
| 0x12 | CORE_CTRL4 | fast charge current limit, bits 5:0 |
| 0x13 | CORE_CTRL5 | trickle charge current limit, bits 3:0 |
| 0x14 | CORE_CTRL6 | discharge current limit, bits 6:0 |
| 0x15/0x16 | CORE_CTRL7/8 | unused by the vendor driver |
| 0x17 | TOP_RECHG_CTRL1 | recharge threshold, 10 mV steps |
| 0x18 | TOP_EOC_CTRL1 | EOC threshold, 10 mV steps |
| 0x19 | TOP_EOC_CTRL2 | EOC current, bits 4:0, 25 mA steps |
| 0x1a | COMASK_CALDIS | unused |
| 0x1b | PM_ENABLE | power meter on, bits 7:4 |
| 0x1c/0x1d | PM_HYST_LEVEL1/2 | hysteresis of the four channels |
| 0x1e/0x1f | PM_V/I_OPTION | unused |
| 0x29 | ID | bit 0 IC generation, 7:6 ES, 5:4 revision |
| 0x40 | COMMON1 | bit 6 thermal shutdown |

### Encodings

- Voltages: 12 bit, `(reg[7:0] << 4) | (next_reg[7:4])`, 1250 µV per step
  (`c:270`, `c:297`, `c:326`, `c:352`).
- Currents: same 12-bit word, 1562.5 µA per step, i.e. `(raw * 15625) / 10`
  µA (same four functions).
- Fast charge limit (0x12, `c:394-456`): 6030 rev 0 and all 6130 parts use
  50 mA steps starting at 50 mA; 6030 rev ≠ 0 uses 75 mA steps up to 350 mA
  and 50 mA steps above.
- Trickle limit (0x13, `c:458-532`): 6130 has its own 50 mA table capped at
  0x0a (550 mA), 6030 rev 0 caps at 0x09 (500 mA), 6030 rev ≠ 0 uses the
  same two-slope table up to 0x08 (550 mA).
- Discharge limit (0x14, `c:534-588`): rev 0 is 50 mA steps up to 6400 mA,
  others the two-slope table up to 6500 mA.
- Recharge/EOC voltage (0x17/0x18, `c:590-646`): `(mV - 2560) / 10`,
  clamped to 0x90 (4000 mV) and 0xb8 (4400 mV).
- EOC current (0x19, `c:648-676`): 25 mA steps, floor 0x04 (100 mA),
  ceiling 0x1f (775 mA).

## 3. What the driver programs at probe

The sequence is the stock initialisation, `s2asl01_init_regs()` at
`c:1143-1201`, in the same order.

| # | Register | Value | Meaning | Stock |
|---|---|---|---|---|
| 1 | 0x10 | bit 0 = 1 (rest kept) | sub power-off mode 1, "power off disabled" | `c:1149-1151` |
| 2 | 0x1b | bits 7:4 = 0xf | power meter on: VCHG, VBAT, ICHG, IDISCHG, continuous conversion; `msleep(100)` only if it was 0 before | `c:1153`, body `c:678-702` |
| 3 | 0x11 | bits 1:0 = 0 | charge mode: current regulation | `c:1159` (or 3, fully on, with `samsung,charge-current-fully-turn-on`, `c:1157`) |
| 4 | 0x11 | bits 3:2 = 3 | discharge mode: no regulation, fully on (hard-coded, `c:1162`) | `c:1162` |
| 5 | 0x14 | 0x7f, or 0x7d when the ID says 6030 rev ≠ 0 | discharge limit 6400 mA, i.e. effectively off | `c:1165` |
| 6 | 0x12 | 0x20 (rev 0 or 6130) / 0x1e (6030 rev ≠ 0) | fast charge limit 1650 mA | `c:1168` |
| 7 | 0x19 | 0x08 | EOC current 200 mA | `c:1171` |
| 8 | 0x18 | 0xb3 | EOC voltage 4350 mV | `c:1174` |
| 9 | 0x0f | bit 0 = 1 (rest kept) | EOC comparator on (stock leaves INOK off, `c:1176`) | `c:1177` |
| 10 | 0x1c | `(4 << 5) \| (4 << 2)` = 0x90, mask 0xfc | VCHG/VBAT power meter hysteresis | `c:1180-1182` |
| 11 | 0x1d | 0x90, mask 0xfc | ICHG/IDISCHG power meter hysteresis | `c:1184-1186` |
| 12 | 0x03 | mask 0x0f → 0 | core interrupt mask 1: nothing masked | `c:1189` |
| 13 | 0x04 | mask 0x03 → 0 | core interrupt mask 2: nothing masked | `c:1191` |
| 14 | 0x02 | mask 0xfe → 0 | power meter interrupt mask: nothing masked | `c:1193` |
| 15 | 0x40 | bit 6 = 1, only if `samsung,thermal-shutdown-enable` and rev 0 | thermal shutdown | `c:1196-1198`, `c:704-720` |
| 16 | 0x29 | read only | ID: generation, ES, revision | `c:1123-1141` |

Register 14 is the vendor quirk, kept deliberately: `0x02` is `PM_INT`, the
*status* register, while the mask register of that block is `PM_INTM`
(0x05). Stock writes the mask into the status register, which clears the
pending power meter interrupts and leaves the real mask alone. Reproducing
it keeps the part in exactly the state stock puts it in; a comment in the
driver says so.

What the vendor DT never programs is equally important: 0x17 (recharge
voltage) keeps its power-on value, and no temporary overrides exist. The
1650 mA figure is the vendor driver's own default, used as-is because this
board's limiter nodes carry no `limiter,chg_current_limit`.

## 4. Charging, discharging, full, recharge

The limiter is a pass element with a comparator, not a charger; the charger
state machine lives elsewhere. What each part of the chain does:

**Charging.** The charge path runs in current regulation (0x11 bits 1:0 =
0) and the fast charge limit in 0x12 is the ceiling for that cell. Stock
changes it at runtime through `FASTCHG_LIMIT_CURRENT`, and the only writer
is the splitter in `sec_battery.c` (`sec_bat_set_limiter_current`,
`sec_battery.c:339-356`). Our driver programs the DT default at probe and
then exposes the same register as `CURRENT_MAX` (read) and
`charge_current_limit` (read/write).

**Discharging.** Discharge regulation is always off (mode 3) and the limit
is 6.4 A, so the cell sees the pack directly. `discharge_current_limit` and
`discharge_mode` stay writable for parity with the vendor interface, which
uses exactly those two when it power-cycles a stuck limiter.

**Full.** The chip's own termination is voltage *and* current: 0x18 =
4350 mV, 0x19 = 200 mA, comparator enabled by 0x0f bit 0. Samsung does not
use the chip's decision alone — `sec_dual_battery.c` polls VBAT and ICHG per
limiter and calls a cell full when

    vbat >= full_condition_vcell[age_step] && ichg <= full_condition_eoc

which for this board is 4400/4380/4360/4340/4290 mV (age steps 0-4,
`evidence/raw/dtbo/entry.3.dts:960-961`) and 45 mA for the main cell
(`main_full_condition_eoc = 0x2d`) and 115 mA for the sub cell
(`sub_full_condition_eoc = 0x73`). On a full cell it sets supplement mode
(0x11 bit 6) so the cell stops taking current while the phone runs from the
charger. That policy is **not** in the driver; the pieces it needs are
(`voltage_now`, `current_now`, `supplement_mode`).

**Recharge.** Two mechanisms exist and neither is used by Samsung's stack:
the chip's own recharge threshold at 0x17 (never written, so it keeps the
power-on value; settable through `recharge_voltage`), and the CTRL1 bit 1
restart pulse (`c:147-155`). Stock decides recharge in `sec_battery.c` by
pack voltage (<= recharge threshold) or by the two cells drifting apart by
more than `force_recharge_margin` = 140 mV
(`evidence/raw/dtbo/entry.3.dts:970`, `sec_battery.c:1603-1626`), then
restarts charging through the charger. The restart bit is therefore not
exposed; it is a one-shot action with no mainline consumer.

**Health.** Stock's check is: power meter enabled, and both VCHG and VBAT
non-zero (`c:365-392`). It is only called from Samsung's battery monitor.
The driver computes the same thing whenever `HEALTH` is read, so nothing
polls. Stock also reads ICHG and IDISCHG in that function purely to print
them; the port skips the two reads.

## 5. The current split is policy, not the limiter

Stock divides the charger's constant current between the cells in
`sec_bat_divide_limiter_current()` (`sec_battery.c:275-337`) and writes the
two results to the limiters with `FASTCHG_LIMIT_CURRENT`
(`sec_battery.c:339-356`). It is not part of the limiter driver and needs
the whole `sec_battery`/`sec_dual_battery`/CISD framework, so it is not
ported. The algorithm, for whoever writes the mainline equivalent:

1. If the charger is PD APDO and the negotiated current is below the APDO
   fast charge current, raise the input to that fast charge current.
2. Pick a zone from the requested total: `<= 1200 mA` zone 1,
   `<= 3000 mA` zone 2, otherwise zone 3.
3. `main = total * main_rate / 100`, `sub = total * sub_rate / 100` with the
   DT rates below.
4. Thermal overrides replace the per-cell value outright
   (`limiter_main_cool*_current`, `limiter_main_warm_current`, and the sub
   equivalents), all absent on this board.
5. Clamp to 0-3150 mA (`0xc4e`) for both cells, and additionally to at
   least 200 mA (`0xc8`) for the sub cell.

Board numbers (`evidence/raw/dtbo/entry.3.dts:964-974`):

| Zone | Total | Main rate | Sub rate | Result main / sub |
|---|---|---|---|---|
| 1 | <= 1200 mA | 40 % (0x28) | 85 % (0x55) | 40 / 85 % |
| 2 | <= 3000 mA | 33 % (0x21) | 77 % (0x4d) | 33 / 77 % |
| 3 | > 3000 mA | 46 % (0x2e) | 60 % (0x3c) | 46 / 60 % |

The rates do not add up to 100 % because each limiter carries only its own
cell; the pair is sized so neither cell exceeds its own limit.

A mainline consumer would write `charge_current_limit` on each cell with
those numbers. Nothing in this patch does it.

## 6. Interfaces

Two power supplies, named exactly as stock names them:
`s2asl01-limiter-main` and `s2asl01-limiter-sub`.

Standard properties (units µV / µA, unlike stock's mV / mA):

| Property | Direction | Source |
|---|---|---|
| `HEALTH` | read | power meter on and VCHG, VBAT non-zero |
| `VOLTAGE_NOW` | read | VBAT, 12-bit word × 1250 µV |
| `CURRENT_NOW` | read | ICHG, 12-bit word × 1562.5 µA |
| `CURRENT_MAX` | read | charge current limit in 0x12, decoded per revision |

Vendor EXT properties have no mainline counterpart, so every one that has a
getter or setter in stock is a sysfs attribute of the same power supply:

| Attribute | Access | Register | Stock |
|---|---|---|---|
| `charge_current_limit` | rw | 0x12 | `FASTCHG_LIMIT_CURRENT` |
| `trickle_charge_current_limit` | rw | 0x13 | `TRICKLECHG_LIMIT_CURRENT` |
| `discharge_current_limit` | rw | 0x14 | `DISCHG_LIMIT_CURRENT` |
| `recharge_voltage` | rw | 0x17 | `RECHG_VOLTAGE` |
| `eoc_voltage` | rw | 0x18 | `EOC_VOLTAGE` |
| `eoc_current` | rw | 0x19 | `EOC_CURRENT` |
| `charge_mode` | rw | 0x11 bits 1:0 | `CHG_MODE` |
| `discharge_mode` | rw | 0x11 bits 3:2 | `DISCHG_MODE` |
| `chgin_ok` | rw | 0x11 bit 7 | `CHGIN_OK` |
| `supplement_mode` | rw | 0x11 bit 6 | `SUPLLEMENT_MODE` |
| `powermeter_enable` | rw | — (write re-runs the whole init) | `POWERMETER_ENABLE` |
| `input_voltage` | ro | 0x07/0x08 | `CHG_VOLTAGE` |
| `discharge_current` | ro | 0x0d/0x0e | `DISCHG_CURRENT` |
| `battery_detect` | ro | detect GPIO | `limiter,bat_det` |
| `battery_enable` | ro | enable GPIO | `limiter,bat_enb` |
| `limiter_data` | rw | 0x00-0x1f dump; write `0xRR 0xVV` | `limiter_data` sysfs |

Two stock behaviours are deliberately kept even though they look wrong:

- writing anything to `powermeter_enable` runs the full init sequence and
  ignores the value (`c:863-866`), because that is what the vendor WA does;
- `discharge_mode` maps 2 (smarter voltage regulation) to 1 on both write
  and read (`c:164-212`).

Not exposed: `RECHG_ON` and `EOC_ON` (one-shot pulses), `ENERGY_NOW` (sub
power-off mode 2) and `CHARGE_FULL` (a `sec_dual_battery` private convention
for supplement mode). None of them has a consumer anywhere in stock, so no
interface was invented for them.

## 7. Read-only test on the device

The driver must be built in (`CONFIG_CHARGER_S2ASL01=m` or `=y`) with
`dt-snippet.dtsi` applied to `sm8350-samsung-b2q.dts`. No writes are needed
and none should be made while the phone is charging.

```sh
# 1. both instances probed
dmesg | grep -i s2asl01
#    s2asl01-limiter-main: ID 0x..: revision N, ES N, IC 6130|6030
#    s2asl01-limiter-sub: ID 0x..: revision N, ES N, IC 6130|6030
ls /sys/class/power_supply/ | grep s2asl01

# 2. the standard properties
for p in health voltage_now current_now current_max; do
        cat /sys/class/power_supply/s2asl01-limiter-main/$p
done

# 3. the vendor knobs, decoded on read
cat /sys/class/power_supply/s2asl01-limiter-main/{charge_current_limit,
    trickle_charge_current_limit,discharge_current_limit,recharge_voltage,
    eoc_voltage,eoc_current,charge_mode,discharge_mode,chgin_ok,
    supplement_mode,input_voltage,discharge_current,battery_detect,
    battery_enable}
cat /sys/class/power_supply/s2asl01-limiter-main/limiter_data
```

Expected properties after probe: `health` good, `voltage_now` around
3.7-4.4 V depending on charge, `current_now` 0 on an idle phone,
`current_max` 1650000, `charge_current_limit` 1650000, `eoc_current`
200000, `eoc_voltage` 4350000, `recharge_voltage` the power-on value (the
driver never writes it), `charge_mode` 0, `discharge_mode` 3,
`discharge_current_limit` 6400000.

Register check with `i2cget` (find the adapter first: the limiters sit on
qupv3 SE1, `i2c@984000`, usually `/dev/i2c-1`; `i2cdetect -y 1` must show
0x38 and 0x39):

| Register | Expected | Notes |
|---|---|---|
| 0x10 | `0x01` | bit 0 set; upper bits preserved |
| 0x1b | `0xf0` | power meter, all four channels |
| 0x11 | `0x0c` | charge mode 0, discharge mode 3; bits 7:4 preserved, check `& 0x0f == 0x0c` |
| 0x14 | `0x7f` (`0x7d` on 6030 rev ≠ 0) | 6.4 A discharge limit |
| 0x12 | `0x20` (`0x1e` on 6030 rev ≠ 0) | 1650 mA fast charge limit |
| 0x19 | `0x08` | 200 mA EOC current |
| 0x18 | `0xb3` | 4350 mV EOC voltage |
| 0x0f | `0x01` | EOC on; upper bits preserved, check `& 1` |
| 0x1c | `0x90` | hysteresis 4/4; check `& 0xfc == 0x90` |
| 0x1d | `0x90` | hysteresis 4/4; check `& 0xfc == 0x90` |
| 0x03 | `0x00` | interrupt mask 1, check `& 0x0f == 0` |
| 0x04 | `0x00` | interrupt mask 2, check `& 0x03 == 0` |
| 0x02 | `0x00` or `0x01` | stock writes the PM mask into the status register; bit 0 is the preserved status bit, check `& 0xfe == 0` |
| 0x40 | unchanged | no thermal shutdown requested in DT |
| 0x29 | ID | bit 0: 1 = 6130, 0 = 6030; 7:6 ES, 5:4 revision; must match the dmesg line |

```sh
for r in 0x10 0x1b 0x11 0x14 0x12 0x19 0x18 0x0f 0x1c 0x1d 0x03 0x04 0x02 0x29; do
        echo -n "main $r "; i2cget -y 1 0x38 $r
done
for r in 0x10 0x1b 0x11 0x14 0x12 0x19 0x18 0x0f 0x1c 0x1d 0x03 0x04 0x02 0x29; do
        echo -n "sub  $r "; i2cget -y 1 0x39 $r
done
```

If 0x12 reads `0x1e` and 0x14 reads `0x7d`, the part is a 6030 with a
non-zero revision; both values are correct for that encoding, and the
dmesg ID line says which.

## 8. Differences from the vendor driver

| # | Vendor | Port | Why |
|---|---|---|---|
| 1 | registers the power supply, then initialises the chip | initialises, then registers | nothing may read a half-configured limiter |
| 2 | `void` register helpers, i2c errors logged and ignored | every write checked, probe fails on error | a limiter that silently did not initialise is worse than one that did not probe |
| 3 | SMBus byte-data helpers | regmap over plain I2C | mainline style; the chip is register-address based, no SMBus framing |
| 4 | enable pins driven with `gpio_direction_output` in the WA | `devm_gpiod_get_optional(..., GPIOD_ASIS)`, never driven | the WA belongs above the driver; only read for reporting |
| 5 | bat_det taken with `of_get_named_gpio`, used as a raw number | `battery-detect-gpios` + `gpiod_get_value_cansleep` | DT bindings; polarity comes from the binding |
| 6 | mV and mA outward, mA internally | µV and µA outward and internally | mainline power supply units; no 1 mA truncation |
| 7 | whole-byte writes for 0x14, 0x19 | field writes with the documented mask | never clobber reserve bits |
| 8 | discharge limit 0x14 full write 0x7f/0x7d | same value through the 6:0 field | bit 7 is reserved and stays as it was |
| 9 | TSD bit set whenever `limiter,tsd-en` is present | same, gated on revision 0 like `c:704-720` | 6130 has no TSD bit |
| 10 | `s2asl01_test_read()` dumps the register block into dmesg after every set | `limiter_data` sysfs attribute | no log spam, same data on demand |
| 11 | reads ICHG and IDISCHG in the health check just to print them | only VCHG and VBAT | same decision, two I2C reads fewer |
| 12 | polled from `sec_battery`'s monitor cycle | nothing | the health result is computed on read; no timer, no workqueue |
| 13 | vendor EXT properties | sysfs attributes + four standard properties | EXT props do not exist upstream |

The vendor irq handler is already `#if 0` in stock (`c:879-907`) and the
work handler it would queue is an empty stub (`c:1117-1121`), so there is
no interrupt path to port. The board file deliberately leaves the interrupt line
unconnected, which is why the driver unmasks everything.

## 9. Build and checks

- `=m`: `CONFIG_CHARGER_S2ASL01=m`, full `make -j20` of the tree plus a
  forced rebuild of the module. `drivers/power/supply/s2asl01_limiter.ko`
  (53088 bytes) compiles and links with no compiler or modpost warnings.
- `=y`: `CONFIG_CHARGER_S2ASL01=y`; `s2asl01_probe` and `s2asl01_init_hw`
  are present in `System.map` and the driver is linked into `vmlinux`.
- `scripts/checkpatch.pl --strict 0011-s2asl01-limiter.patch`: 0 errors,
  0 checks, 2 warnings, both expected for this series:
  - "added, moved or deleted file(s), does MAINTAINERS need updating?" —
    the tree's patch series does not carry MAINTAINERS changes;
  - "DT binding docs and includes should be a separate patch" — the
    deliverable is a single patch, so driver, Kconfig, Makefile and binding
    travel together on purpose.
- `make dt_binding_check DT_SCHEMA_FILES=...samsung,s2asl01.yaml` **could
  not run**: `dt-doc-validate` is not installed and the `dtschema` Python
  module is missing, so the YAML was only reviewed by hand against existing
  bindings (explicit `uint32`/`string` `$ref`s, `unevaluatedProperties`,
  `power-supply.yaml` included).

## 10. Files

| File | Content |
|---|---|
| `0011-s2asl01-limiter.patch` | driver, Kconfig, Makefile, binding |
| `dt-snippet.dtsi` | i2c1 nodes and the five pin states, stock values in comments |
| `config.txt` | `CONFIG_CHARGER_S2ASL01=m` |
| `REPORT.md` | this file |
