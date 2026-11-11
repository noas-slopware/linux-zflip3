# b2q-siop

Stock's skin temperature (LRP2) and the CPU and GPU limits Samsung throttles on with it,
the way the stock firmware does them. On stock this is split between Samsung's thermal HAL
(`/vendor/bin/hw/vendor.samsung.hardware.thermal@1.0-service` with
`/vendor/etc/mercury.json`), SamsungDeviceHealthManagerService (SDHMS, its SIOP table
`siop_b2q_sm8350.xml`) and the kernel's `cpufreq_limit`. `b2q-siopd` does all three.

## What it does, every 10 s (the HAL's interval)

1. **Inputs, as the HAL reads them** (deci-Celsius):
   - PMK8350 ADC thermistors, from the raw codes (kernel patch 0107) through stock's own
     tables, which differ from mainline's generic 100 kOhm table by up to 2 C: AP `ap_thm`,
     WIFI `wf_thm`, CF `cf_thm` (sec_thermistor, one sample), BAT `wpc_thm`, USB `usb_thm`,
     CHG `chg_thm`, SUBBATRAW `sub_bat_thm` (sec_battery, five samples less the extremes).
   - The modem's thermistors (patch 0108): PATHM `lte-pa1-thermal`, PA1THM `lte-pa2-thermal`,
     LRPTHM `mmw-pa1-thermal`, MMWTHM `mmw-pa3-thermal`.
   - The HAL's virtual thermistors: FCAM = USB, +8 C while the front camera (IMX374) is
     open, smoothed by 0.264 per tick; UPSPK = CF plus 5 % of how far the Earpiece amp is
     above it, DNSPK = USB plus 30 % of the Speaker amp's, both smoothed by 0.15. The amp
     temperature is the CSPL firmware's real-time log variable 111 (the `RTLOG_*`
     controls), read as stock does while the amp's DSP runs; idle, it counts as -1 C.
2. **LRP2**: mercury.json's front and rear heatmaps, collapsed to one linear form per heat
   source (AP2, CHG2, MEM2, WIFI2) and face; LRP2 is the highest, the rear faces only once
   the phone has been folded (SW_LID) for 30 s. If any input is missing, LRP2 is invalid,
   which releases every limit, as on stock.
3. **SIOP**: the level (`siop_default.xml`'s levels on LRP2), then the AP component's
   CPUFreqMax and GPUFreqMax. Both are step 0: the limit moves along Samsung's frequency
   list toward the table's value, at most every 9 s (CPU) or 19 s (GPU), 0 to 3 entries at a
   time depending on how fast LRP is rising and on the level, and all at once once LRP or
   the battery is at or below the release temperature (35 C). A level is left only below
   the threshold under it.
4. **Applying CPUFreqMax** as stock's cpufreq_limit: the value is on its merged list (prime
   frequencies above half the little cluster's top, then the little cluster's halved). At
   or above the lowest such prime frequency, prime is capped at it and gold at the fastest
   gold frequency whose voltage is not above the next prime step's (`vol_based_clk`, OPP
   voltages from debugfs); below it, the little cluster is capped at twice the value (at
   most 1612800) and gold and prime go to their lowest frequency. The caps are written to
   each policy's `scaling_max_freq`, GPUFreqMax to the GPU's devfreq `max_freq`, only when
   they change, and released on exit.

The status of the last tick is in `/run/b2q-siop/status`.

## Model data

None of Samsung's data is in this repository. `tools/extract-siop-data.py --sdhms <apk>`
writes `/usr/share/b2q-siop/model.conf` (into `out/firmware/`) from the stock vendor tree
(`mercury.json`), the stock dtbo (thermistor tables) and SDHMS's APK (SIOP tables), and
checks the collapsed forms against a literal evaluation of the HAL's heatmap.

## Not ported

Everything in the SIOP table except the AP component's CPUFreqMax and GPUFreqMax:
OverLimit, the other components (display brightness, modem, camera, charging, Wi-Fi), all
scenarios (screen off, calls, apps), limiter delays and conditions, and stock's per-sensor
debug overrides. The HAL's 5 s interval during boot is not reproduced (always 10 s).

## Differences from stock

- Stock's CPUFreqMax is a private QoS request of cpufreq_limit; here it is each policy's
  `scaling_max_freq`, which other tools could also write.
- BAT is a fresh ADC reading; stock's `battery/temp` is sec_battery's cached reading of
  the same channel and table.

## Testing

`test/sim.py <b2q-siopd> <model.conf>` runs the daemon against a fake sysfs tree with the
phone's OPP tables and voltages through a heat-up, fold, camera, music and cool-down
scenario, and checks every tick (inputs, LRP2, level, limits, the values written) against
a separate port written from the decompiled stock code. It has not been checked against
stock's own output: no SDHMS log from this phone exists.
