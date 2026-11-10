# Plan: keep the IMS PDN alive across a ModemManager reset

Status: open, deferred to the next work session (2026-11-10 or later, after the Claude
weekly usage reset).

## Goal

`systemctl restart ModemManager` must not tear down `qmapmux0.3`, `b2q-ims-bearer` must stay
active, `b2q-imsd` must stay registered, and the default data PDN on `qmapmux0.0` must come
back with its address and default route.

## Current behaviour

`ModemManager` builds its data format on the `ipa` net driver in `src/mm-port-qmi.c`:

- `internal_reset()` calls `mm_port_net_link_setup(MM_PORT_NET(data), FALSE, ...)` on
  `rmnet_ipa0`.
- `net_link_down_ready()` then calls `qmi_device_delete_all_links()` on that parent.
- `qmapmux0.3` is a link on the same parent, so it is deleted.
- `b2q-ims-bearer` watches `RTM_DELLINK` and exits, systemd restarts it, and `b2q-imsd`
  briefly deregisters while the IMS PDN is recreated.

Data still works because the full reset gives the modem the clean state its WDA data format
machine expects.

## Failed attempt

`patches/modemmanager/0002-port-qmi-reset-only-the-default-mux-link-on-IPA.patch`:

- On `ipa`, skip the parent link reset entirely.
- Delete only `qmapmux0.0` through a dedicated `delete_default_link_ready()` callback.
- Complete the reset task normally so `internal_setup_data_format()` runs.

Result: `qmapmux0.3` survived, but every bearer connect failed with:

```
[qrtr0/qmi] current data format setup:
    kernel data modes: mux-rmnet
    link layer protocol: raw-ip
    aggregation protocol ul: disabled
    aggregation protocol dl: disabled
<wrn> [modem0/bearer1] connection attempt: No more data format combinations supported
```

With the IMS PDN up, WDA `Get Data Format` reports `raw-ip` with aggregation disabled for
the default endpoint. `check_data_format_combination()` needs a QMAPV5 combination for
`MUX_RMNET` with `SET_MULTIPLEX`, finds none, and returns that error. The IMS bearer itself
is healthy; the default PDN cannot configure its QMAP data format while the IMS PDN owns the
aggregation state.

Do not re-apply 0002 as-is. It is kept only as a record of the failure.

## Options

1. **Order the IMS bearer after the default data PDN.**
   Make `b2q-ims-bearer` wait until `qmapmux0.0` exists and is up, or until ModemManager
   reports a connected data bearer, then start profile 4 on mux 3. The modem sees the default
   QMAP setup first, and the IMS PDN joins afterwards.
   - Pro: uses the existing full reset and needs no WDA changes.
   - Con: IMS does not come up when the phone is on Wi-Fi only and has no cellular data.
     Needs a fallback that starts the IMS bearer anyway when data is unavailable, which
     reintroduces the ordering problem in that case.

2. **Stop and restart the IMS bearer around the reset.**
   A helper stops `b2q-ims-bearer` before ModemManager resets the parent, lets the data
   setup finish, then starts it again.
   - Pro: deterministic, small change.
   - Con: IMSD still drops briefly during each ModemManager restart. Better than the current
     crash but does not meet the "no drop" goal.

3. **Save and restore `qmapmux0.3`.**
   Let ModemManager do the full reset, but have a helper remember the IMS link name, mux id,
   IPv6 address and routes, and recreate them after the data setup. `b2q-ims-bearer` would
   have to ignore the temporary `RTM_DELLINK` (or keep its WDS handle across it).
   - Pro: no modem state machine changes.
   - Con: the WDS network is likely torn down with the link; the helper must restart the PDN
     anyway, so `b2q-imsd` still drops.

4. **WDA/DPM-aware reset in ModemManager.**
   Keep deleting only `qmapmux0.0`, but skip the WDA data format setup when the modem already
   has a QMAP data path. After deleting the default link, force the bearer context to
   `dap = QMAPV5`, `llp = RAW_IP` and let `mm_port_qmi_setup_link()` add the new link. The
   data call then starts without another WDA `Set Data Format`.
   - Pro: preserves `qmapmux0.3` and keeps IMS up.
   - Con: needs experiments to see whether the modem accepts a new link while the IMS QMAP
     state is active, and whether the kernel `rmnet_ipa0` is already in QMAP pass-through.
   - This is the recommended first prototype.

5. **Investigate the DPM endpoint mapping.**
   `dpm_open_port()` uses the TX/RX endpoint ids from sysfs. With the IMS PDN active those
   ids may describe the IMS endpoint, and WDA `Get Data Format` may then return the IMS
   endpoint's disabled aggregation for the default endpoint. Compare the sysfs endpoint ids,
   the DPM open request and the WDA `endpoint_info` TLV with the IMS PDN up and with it
   stopped. This may explain the disabled result without changing the reset at all.

6. **Use the stock Samsung data path as the reference.**
   Check the Samsung modem/QMI userspace or the stock IMS/data manager for the order it uses
   between the default PDN and the IMS PDN, the mux ids, WDS profile numbers and WDA calls.
   Do not assume the mainline ModemManager sequence matches Samsung's.

## Recommended next step

Prototype option 4 on top of the current `1.24.2-10`:

1. Add `MM_PORT_QMI_IPA_PRESERVE_LINKS` behaviour on `ipa` only.
2. In `internal_reset()`, delete only `qmapmux0.0`.
3. In `internal_setup_data_format()`, when the net driver is `ipa` and `qmapmux0.3` exists,
   set `ctx->kernel_data_modes_current = MUX_RMNET`, `ctx->wda_llp_current = RAW_IP`,
   `ctx->wda_ul_dap_current = ctx->wda_dl_dap_current = QMAPV5` and return success without
   querying WDA or opening DPM again.
4. Let the existing `setup_link()` add `qmapmux0.0` and connect the bearer.
5. If the link add or the data call fails, fall back to the old full reset for that attempt.

If option 4 does not connect, investigate option 5 before trying option 1.

## Test checklist

- `ip -br link`: `qmapmux0.3` stays `UP,LOWER_UP` across `systemctl restart ModemManager`.
- `qmapmux0.0` returns with IPv6 and the default route.
- `ping6 2001:4860:4860::8888` works.
- `b2q-ims-bearer` does not restart, or if it does, `b2q-imsd` re-registers within the
  existing retry window.
- `b2q-imsd` sends and receives SMS and places a VoLTE call after the restart.
- Repeat with data disconnected, with Wi-Fi only, and with a call active.
- Check `journalctl -u ModemManager` for `No more data format combinations supported`,
  WDA failures, and bearer connect retries.

## Files

- `patches/modemmanager/0002-port-qmi-reset-only-the-default-mux-link-on-IPA.patch`:
  failed attempt, not applied.
- `patches/modemmanager/PKGBUILD`: current `1.24.2-10`, only 0001 and 0003 applied.
- `src/mm-port-qmi.c`: `internal_reset()`, `internal_setup_data_format()`,
  `check_data_format_combination()`, `dpm_open_port()`.
- `userspace/imsd/src/ims_bearer.c` and `b2q-ims-bearer.service`: IMS PDN on mux 3,
  `RestartMaxDelaySec=15`.
