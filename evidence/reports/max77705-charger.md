# MAX77705 charger: stock behaviour on mainline 7.3.1

Port of the SM-F711N (b2q) charger to the mainline `max77705_charger` driver, so the
chip ends up in the state Samsung's firmware puts it in and so a cable sets the
currents Samsung's firmware sets.

Nothing has been run on the phone. All of this is source study against Samsung's
kernel (`.cache/samsung/kernel` in this repo, paths below are relative
to it) and the stock device tree dump (`evidence/raw/dtbo/entry.3.dts`), plus a local
build and `checkpatch`.

## Contents

| file | what |
|---|---|
| `0010-power-supply-max77705-port-Samsung-charger-setup-and-BC1.2.patch` | driver and header |
| `0011-dt-bindings-power-supply-maxim-max77705-add-properties.patch` | binding for the new properties |
| `dt-snippet.dtsi` | device tree for `&i2c7`, appended to the board DTS |
| `config.txt` | options the port needs |

Apply with `patch -p1` from a clean 7.3.1 tree, in order. Both patches are
`checkpatch --strict` clean (0 errors, 0 warnings), and they were verified to apply
to pristine copies of the three files and reproduce the modified tree byte for byte.

## What the driver now does that it did not before

* `initialize()` takes the switching frequency, top-off time and BAT to SYS OCP
  settings from DT instead of hardcoding 1.5 MHz and 30 min, sets `RECYCLE_EN`,
  `UNOILIM`, clears a factory-left `DIS_AICL`, programs VCHGIN by charger presence,
  selects the CHGIN input, clears the bootloader's auto ship mode bit, and writes
  `FMBST`/`FGSRC`/`SHIPMODE`.
* BC1.2. The USB-C block at 0x25 reports the port type in `REG_BC_STATUS`. The
  charger now takes the MFD's `regmap_muic` (`maxim,pmic`), requests the PMIC's
  USBC interrupt (`interrupts` entry 2, index 3 in `max77705_irqs`), unmasks only
  `CHGTypI` (bit 1) and `VBUSDetI` (bit 5) in `UIC_INT_M`, and on each event sets
  VCHGIN from `VBUSDET` and the two current limits from the DT arrays.
* `CHGIN_LIM` is encoded like stock, `current / 25 mA - 1` (stock
  `max77705_set_input_current()`, drivers/battery/charger/max77705_charger/max77705_charger.c:625-628,
  writes `500 mA` as 0x13). Mainline wrote `current / 25`, one step high.
* The charge current limit is clamped to 3.15 A, stock's maximum
  (max77705_charger.c:650-651).

## Registers written at probe

The charger is at i2c7 0x69 (`I2C_ADDR_CHG (0xD2 >> 1)`, stock
drivers/mfd/maxim/max77705.c:77). Writes are field-level read-modify-write, so the
"byte" column is the result assuming the other bits hold what the bootloader left
(`CNFG_00` 0x05, `CNFG_02` 0x4a, `CNFG_04` 0x13, `CNFG_08` 0x00, `CNFG_09` 0x93,
recorded at evidence/SM-F711N-m0.md:352).

| reg | written | byte | stock |
|---|---|---|---|
| 0xb7 `CNFG_00` | `MODE` bits3:0 = 0x5 (CHG\|BUCK), `WDTEN` bit4 = 0 | 0x05 | :944-945; watchdog differs, see below |
| 0xb8 `CNFG_01` | `FCHGTIME` bits2:0 = 0, `RECYCLE_EN` bit3 = 1, `CHG_RSTRT` bits5:4 = 3, `CHG_PQEN` bit7 = 0 | 0x38 | :932-941 |
| 0xb9 `CNFG_02` | `OTG_ILIM` bits7:6 = 1 (900 mA); `CC_LIM` untouched at probe | 0x4a | :948-950 |
| 0xba `CNFG_03` | `TO_ITH` bits2:0 = 0 (150 mA), `TO_TIME` bits5:3 = 7 (70 min), `SYS_TRACK` bit7 = 1, `AUTO_SHIPMODE` bit6 = 0 | 0xb8 | :962-968, :1040 |
| 0xbb `CNFG_04` | `CHG_CV_PRM` bits5:0 = 0x1c (4440 mV) | 0x1c | :971, `battery,chg_float_voltage = <0x1158>` at entry.3.dts:135 |
| 0xbc `CNFG_05` | `B2SOVRC` bits3:0 = 0 (off), `UNOILIM` bits6:4 = 6 (1.0 A) | 0x60 | :765-767, :953-955 |
| 0xbd `CNFG_06` | `CHGPROT` bits3:2 = 3, `DIS_AICL` bit4 = 0, `LX_SLOPE` bits6:5 = 3, `B2SOVRC_DTC` bit7 = 1 | 0xec | :915-917, :923-925, :769-771 |
| 0xbe `CNFG_07` | `FMBST` bit2 = 1, `FGSRC` bit1 = 0, `SHIPMODE` bit0 = 0 | 0x04 | :986-987, :1013-1015, :583-584 |
| 0xbf `CNFG_08` | `FSW` bits1:0 = 0 (3 MHz) | 0x00 | :736-738 (from `charger,fsw = <0>`, entry.3.dts:24) |
| 0xc0 `CNFG_09` | `CHG_EN` bit7 = 1 (at probe end, mainline's `max77705_charger_enable()`); `CHGIN_LIM` untouched | 0x93 | :1023-1024 |
| 0xc2 `CNFG_11` | `VBYPSET` bits6:0 = 0 (5.0 V) | 0x00 | :1027-1028 |
| 0xc3 `CNFG_12` | `VCHGIN` bits4:3 = 1 if `CHGIN_OK` else 0, `CHGINSEL` bit5 = 1, `WCIN` bits2:1 = 0, `DISKIP` bit0 = 0 | 0x28 with a charger, 0x20 without | :977-983, :1626-1627 (wired), :1608-1609 (no cable) |

Two things stock does here that this port does not, both deliberate:

* `WDTEN` stays 0. Stock enables the watchdog (:1010, :1017) and only kicks it from
  `max77705_get_charging_health()` (:309), which runs from property reads (:1299) and
  the charger interrupt work (:1942) — both driven by sec-battery's polling loop, 10 s
  basic and 30 s while charging (sec_battery.c:2918-2924, `battery,polling_time =
  <10 30 30 30 3600>` at entry.3.dts:50). Mainline has no such loop, so an enabled
  watchdog would reset the chip and stop charging once the AP sleeps past the timeout.
* `CHGINSEL` is written once at probe instead of when the cable type arrives. Stock
  sets it in `max77705_change_charge_path()` from the ONLINE handler (:560-576), which
  sec-battery calls a moment after boot. Same end state.

`CNFG_13` and `CNFG_14` are not written by either driver. Active discharge
(`MAINCTRL1` bit0, stock :1021) is already set by the mainline MFD
(drivers/mfd/max77705.c:197).

## Registers written on cable events

`setup_usbc()` runs once at probe, then every `UIC_INT` event does:

| reg | written | value |
|---|---|---|
| 0x25:0x02 `UIC_INT` | read (clears pending) | — |
| 0x25:0x08 `BC_STATUS` | read | bit7 `VBUSDET`, bits1:0 `CHGTYP` |
| 0xc3 `CNFG_12` | `VCHGIN` bits4:3 | 1 (4.6 V) when `VBUSDET`, 0 (4.5 V) otherwise — stock :1608-1609, :1626-1627 |
| 0xc0 `CNFG_09` | `CHGIN_LIM` bits6:0 | `limit / 25 mA - 1` for a known port type — stock :625-628 |
| 0xb9 `CNFG_02` | `CC_LIM` bits5:0 | `limit / 50 mA` — stock :650-656 |

Port types and the DT values from the board's cable-info:

| `CHGTYP` | port | input / charge | stock cable-info |
|---|---|---|---|
| 0 | nothing detected | untouched | — |
| 1 | SDP | 475 / 550 mA | `current_group_12`, entry.3.dts:1094-1098 (cable 4 = `SEC_BATTERY_CABLE_USB`) |
| 2 | CDP | 1500 / 1500 mA | `current_group_3`, entry.3.dts:1040-1044 (cable 5 = `..._USB_CDP`) |
| 3 | DCP | 1800 / 2100 mA | defaults, entry.3.dts:1022-1023 (cable 3 = `..._TA` is in no group) |

`UIC_INT_M` (0x25:0x0e) ends at 0xdd: the mainline MFD masks the whole block at probe
(drivers/mfd/max77705.c:127-131) and the charger unmasks exactly bits 1 and 5. Stock
leaves the block at `REG_UIC_INT_M_INIT` 0x04 (include/linux/usb/typec/maxim/max77705.h:96),
i.e. everything unmasked but bit 2; only these two bits are serviced here, the rest
stay masked so the line cannot storm. `CHGTYP` is `REG_BC_STATUS` bits1:0 and `VBUSDET`
is bit7 (max77705-muic.h:248-255, `REG_BC_STATUS 0x08` in max77705.h:71).

On detach only `VCHGIN` returns to 4.5 V; the current limits keep their last value,
which is what stock's handler does too. `power_supply_changed()` is called after every
update.

## What is not ported, and why

| stock | why not |
|---|---|
| Watchdog enable (:1010, :1017) | no kick path in mainline, see above |
| AICL loop, 100 mA steps down to a 300 mA floor (:492-517, max77705_charger.h:318-319) | mainline already has its own AICL handler (drivers/power/supply/max77705_charger.c:46-81): one 25 mA step per 100 ms, no floor. Changing it would mean rewriting pre-existing mainline behaviour that is shared with every other MAX77705 board, so the difference is left visible: stock stops at 300 mA, mainline keeps stepping one LSB at a time and can reach 0x00 (25 mA). Worth a separate patch if you want it |
| `charger,enable_sysovlo_irq` (:2317-2318, :2537-2551, :1045-1060, :2226-2238) | unmasks PMIC `SYSTEM_INT_MASK` bit5 while no cable is attached (only from :1610-1611) and reports `POWER_SUPPLY_EXT_PROP_SYSOVLO` to sec-battery. Nothing in mainline consumes that property, and the mask dance exists for Samsung's battery framework |
| `charger,fac_vsys = <0x1130>` (:22 in the dump, used at :258-263) | factory-mode CV override, `CONFIG_SEC_FACTORY` only |
| Jig detection (`fuelgauge,jig_gpio` on tlmm 84, `fuelgauge,jig_low_active`, :989-1015) | `FGSRC` is written 0, which is what the read gives with no jig attached (active-low pin, high when idle); no jig handling is needed for normal use |
| `max77705_set_fw_noautoibus()` (:630-631, :1602-1603) | USBC firmware opcode, stock sends it from the current setters and the ONLINE handler. Without the CCIC firmware driver the block's defaults stand, and the port type is read from the same registers either way |
| Wireless path: `CHGINSEL` = 0, `CNFG_10` limits, `mfc-charger` | mainline has no mfc-charger driver for this board, so the charger stays on CHGIN, which is the state stock uses with a cable attached |
| Slow charging / SIOP / AFC / APDO / charging time limits | sec-battery and the MUIC driver, not the charger: they decide a number and hand it over as `CONSTANT_CHARGE_CURRENT` / `INPUT_CURRENT_LIMIT`, which this driver already implements |

One more divergence, in an edge case: a requested input current below 100 mA is
clamped to 100 mA here, while stock writes 0 (25 mA) for anything under 100 mA
(:625-626). No DT value or cable path goes that low.

## How this was checked

```
cd .cache/linux-7.3.1-chg
nice -n 19 ionice -c3 make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j10 \
	drivers/power/supply/max77705_charger.o      # clean, also with W=1
scripts/checkpatch.pl --no-signoff --strict <patch>   # 0 errors, 0 warnings
```

`dt_binding_check` was not run: `dt-doc-validate` and dtschema are not installed here.

Both patches were applied with `patch -p1` to pristine copies of
`drivers/power/supply/max77705_charger.c`, `include/linux/power/max77705_charger.h`
and `Documentation/devicetree/bindings/power/supply/maxim,max77705.yaml`, and the
result is byte-identical to the tree that was built.

## Read-only checks for the phone

Nothing here has been run on the device. With the patches applied and the snippet
added, these reads show the state the driver programmed. Use `i2cdetect -l` to find
the bus that carries the PMIC; it is i2c7 in DT but the controller number varies.

```
i2cdetect -y <bus>                 # expect 0x66 (PMIC), 0x69 (charger), 0x36 (fuel gauge)

i2cget -y <bus> 0x69 0xb7          # CNFG_00  0x05
i2cget -y <bus> 0x69 0xb8          # CNFG_01  0x38
i2cget -y <bus> 0x69 0xba          # CNFG_03  0xb8
i2cget -y <bus> 0x69 0xbb          # CNFG_04  0x1c  (4440 mV)
i2cget -y <bus> 0x69 0xbc          # CNFG_05  0x60
i2cget -y <bus> 0x69 0xbd          # CNFG_06  0xec
i2cget -y <bus> 0x69 0xbe          # CNFG_07  0x04
i2cget -y <bus> 0x69 0xbf          # CNFG_08  0x00  (3 MHz)
i2cget -y <bus> 0x69 0xc0          # CNFG_09  0x93 idle, 0xc7 with an 1.8 A DCP
i2cget -y <bus> 0x69 0xc2          # CNFG_11  0x00
i2cget -y <bus> 0x69 0xc3          # CNFG_12  0x20 idle, 0x28 with a cable
i2cget -y <bus> 0x69 0xb9          # CNFG_02  OTG_ILIM + last charge current

i2cget -y <bus> 0x25 0x0e          # UIC_INT_M 0xdd with the second interrupt
i2cget -y <bus> 0x25 0x08          # BC_STATUS: bit7 cable, bits1:0 port type
```

Do not `i2cget` 0x25 0x02: that register clears its bits on read and would eat a
pending cable event.

Then, with a cable of each kind:

```
cat /sys/class/power_supply/max77705-charger/online
cat /sys/class/power_supply/max77705-charger/input_current_limit
cat /sys/class/power_supply/max77705-charger/constant_charge_current
```

expect 475000/550000 on a PC port, 1500000/1500000 on a CDP, 1800000/2100000 on a
dedicated charger.
