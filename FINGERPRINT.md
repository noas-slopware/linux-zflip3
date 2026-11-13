# Fingerprint (Goodix GW36T1): TZ inventory and the QSEECom path

Status, 2026-11-10 evening: **working end to end.** Enrolled from Settings (kcm_users), and
touching the sensor unlocks the lock screen through fprintd. See "Working end to end" below.

Earlier, 2026-11-10: **go.** On kernel #1 (0001-0047, probe from `patches/linux/0040-*`), the
stock `securefp` TA loads and answers from mainline Linux through the legacy QSEECom calls:

```
qseecom: found qseecom with version 0x1402000
qseecom-probe: APP_LOOKUP securefp: -2, app id 0
qseecom-probe: APP_START securefp: mdt 7464, image 7490705 bytes at 0x00000000fe200000
qseecom-probe: APP_START securefp: 0, app id 11
qseecom-probe: APP_SHUTDOWN 11: 0
qseecom-probe: send securefp cmd 0x10 arg 0x0: 0      (BAuth_Type_Check, sensor unpowered)
qseecom-probe: rsp 00000000: 00000000 00000000 ...   (status 0, value 0)
```

So gate 3 (TZ accepts the load from this boot chain) is passed, no listener blocked the load or the
first command, and unload works. The sensor was not powered (L16 is not described in the DT and no
Linux driver drives reset/IRQ), so the type check proves the transport, not the sensor. Next:
power the sensor the way stock does (`gw3x_common.c`: `VDD_BTP_3P3` on S2MPB02 L16, reset GPIO
39, IRQ GPIO 38), then repeat `BAuth_Type_Check` and expect a non-zero sensor type.

**Sensor identified, 2026-11-10** (kernel #2 with `patches/linux/0048-*`): with stock's power-up
done from userspace (`echo enabled > /sys/bus/platform/devices/fingerprint-power/state`, 5 ms,
`gpioset -c gpiochip5 -z -t 3ms,0 39=0` for the 3 ms reset pulse, 60 ms) and the argument stock
passes, the TA answers `BAuth_Type_Check` with status 0 and value **6**:

```
qseecom-probe: send securefp cmd 0x10 arg 0x12: 0
qseecom-probe: rsp 00000000: 00000000 00000006 ...
```

With the rail off and reset low the same call returns 0, so the TA really reaches the GW36T1 over
its secure SPI bus. Where the numbers come from (stock `libbauthserver.so`,
`FPBAuthService::check_gpio_snsr_type`): it reads `/sys/class/fingerprint/fingerprint/name`
(stock's kernel fills it from DT `goodix,chip_id = "GW36T1"`) and, for "GW36T", stores session
type 6 (passed to `BAuth_SessionOpen`, which picks `securefp`) and 18 (0x12, passed to
`BAuth_Type_Check`). Power control in stock goes through `/dev/goodix_fp` ioctls from
`gfDevicePowerCtrl` (0x6707/0x6708), `gfDeviceSpiCtr` (0x40046705/0x6706), `gfDeviceReset`
(0x6702) and `gfDeviceEnableInt` (0x6703/0x6704); on mainline the same is the regulator-output
`state` file and libgpiod on gpiochip5 lines 38/39.

Next (done since, see below): a userspace interface to the TA, then the enroll and identify
command flows from `libbauthserver.so`.

Pins, 2026-11-10: GPIO 38 (BTP_INT_N) and 39 (BTP_RST_N) were read and driven from userspace
through `/dev/mem` (TLMM 0x0f100000 + n * 0x1000, `scratch/tlmm.py`) on kernel #1 without any
reset: both come up as GPIO, input, pull-down, 2 mA; 39 drives low/high/low and reads back; 38
stays 0 with the sensor unpowered. So they are not TrustZone-protected, and 0048 un-reserving
them in the DT is safe on that count.

**fprintd, 2026-11-10: enrolls to 100%, then the TA cannot seal the template.**

- **Pieces:**
  - **Kernel:** `/dev/qsee-app` (`patches/linux/0049-*`, `CONFIG_QCOM_QSEE_APP=m`). One TA per fd: LOAD, then SEND with the response read back at `ALIGN(req_len, 64)`.
  - **libfprint:** driver `samsung_securefp`, `patches/libfprint/` (0001 adds a misc-device udev subtype, 0002 is the driver). It runs stock's loop: send a command, serve the "op" the TA hands back (4 wait for the IRQ, 3 wait for lift, 7 sleep, 8 reset), repeat. GPIO lines are looked up by DT name, power is the `fingerprint-power` regulator-output, and templates live in fprintd's print files.
  - **fprintd:** 1.94.5 from extra. Its unit needs a drop-in allowing `/dev/qsee-app` and `char-gpiochip`, which the libfprint package ships.
  - **Request layouts:** `scratch/fp-ta/ta-layouts.md` and `hal-flows.md`.
- **What works:** `fprintd-enroll` finds the device and passes its duplicate check. Every touch fires GPIO 38. Progress rises 5% per good touch (20 touches), and a bad touch gives status 0x27 with quality flags (fprintd shows retry-scan). No HAT or HMAC key was pushed. Prepare, Enroll_Init and Enroll_Do don't need one.
- **What fails:** at 100% Enroll_Do returns **0x47** with a template length of -10. Static analysis (`scratch/fp-ta/ta-enroll-0x47.md`) traces it to sealing the template. `get_uniquekey` "sep" calls `HwVaultHal_deriveKey`, which does `qsee_open(0x89)` and asks for a 64-byte key under the context "Samsung Biometrics SEP key". Any failure there gives 0x47; the HAT, sid and storePath play no part.
- **HwVault:** service 0x89 is the `hwvault` TA (NON-HLOS `image/`, ARM32). On stock it runs under `hermesd` through `libhwvault`, which also serves a QSEECom listener, and its strings show key wrapping through the SPU (`wrap_using_spu`, `HV_TZ_CMD_SSP_*`). Whether securefp's derivation needs the SPU, the listener, or only the loaded TA is being decoded (`scratch/fp-ta/hwvault-service.md`).
- **hwvault on Linux (2026-11-10, kernel #3, `/dev/qsee-app` with ELF32 support):**
  - The 32-bit `hwvault` TA loads (sbuf 0x14100, stock `hv_msg` framing, `scratch/fp-ta/hwvault.py`). `HV_TZ_CMD_TEST` 0x2710 returns 1000, and every response carries the TA's own log lines (tag 0x020003e8).
  - **Checkpoint A passed:** with hwvault loaded during a full enroll, Enroll_Do at 100% returns **0x48** instead of 0x47. securefp reaches service 0x89, which reports the ROT slot (0xb) empty, exactly as `hwvault-service.md` predicted.
  - Filling the slot fails at the SPU: `GENERATE_HWVAULT_ROT` 0x271b returns 9936, and the TA logs `wrap_using_spu:314 strongbox_wrap err -64` (no hang). `strongbox_wrap` is service 0x96, Qualcomm keymaster64 (`km41.mbn`), which talks to the SPU app `keym1p` over spcom.
  - -64 is `KM_ERROR_KEYMASTER_NOT_CONFIGURED` (AOSP `keymaster_defs.h`). keymaster64 is resident (app id 1, loaded by ABL), and the SPSS and its apps (`keym1p`, `crypt1p`, `asym1p`) are started by UEFI (stock `qcom,boot-enabled`), so neither needs loading. What stock's StrongBox HAL and `init_spu_worker` do at boot is in `scratch/fp-ta/keymaster64-configure.md` and `spu-path.md`. Replayed by `scratch/fp-ta/km64.py init`:
    1. `KM_NEW_CONFIGURE` 0x2116 (QCBOR: os 150000, patch 202608, vendor patch 20260805, the stock values) returns 0. The hwvault wrap moves on to -10007, "no SPU buffer".
    2. `QSEE_APP_IOC_VMBUF`, a new ioctl in 0049: 0x5000 bytes assigned to VMID 0x22 (`CP_SPSS_SP_SHARED`) with `qcom_scm_assign_mem`, as stock's ION `sp_mem` heap does.
    3. `SPU_INIT` 0x20d `{u32 0x20d, u64 pa, u32 0x5000}` returns 0. The wrap moves on to **-2** (hwvault ret 9998). No hang, no listener request so far.
  - The buffer has to stay assigned while keymaster64 uses it, so the descriptor that owns it lives in a long-running holder (the stock HAL daemon's role), not in fprintd's per-operation open.
- **Working end to end (2026-11-10, kernel #6, claire 0.1.0-6):**
  - The root key needed the SPSS's NVM served from HLOS, the way stock `spdaemon` and `sec_nvm` do it, and `claire` now does that at boot:
    1. **Persist:** mounts the persist partition at `/mnt/vendor/persist` (`mnt-vendor-persist.mount`), where the secnvm copies are.
    2. **Channels:** binds the SPSS edge's `sp_kernel` channel to `rpmsg_chrdev`, then every `sec_nvm_<app>` channel.
    3. **sec_nvm:** serves each `sec_nvm_<app>` channel with its own manager (`userspace/claire/src/nvm.c`, ported from stock `sec_nvm` with GhidraMCP).
    4. **Keymaster:** on NVM_READY (its kernel partition open and committed), opens `sp_keymaster` and runs `KM_NEW_CONFIGURE` and `SPU_INIT`. SPU_INIT returns 0 here.
    5. **hwvault:** loads hwvault and generates the root key, then sets it (`GENERATE_HWVAULT_ROT` returns 0 with a 185-byte blob, `SET_HWVAULT_ROT` returns 0). The blob is kept in `/var/lib/claire/hwvault.hvr` and set again on later boots.
  - **What the SPSS asked for during the boot that worked:** IsCommit `0x5` (version 3), then Open SKP `0xc` on `sec_nvm_sp_nvm` (the kernel partition, 32 blocks, ARC marker) and Commit SKP `0x8`. Next came GET_SBDB_ADDR `0xd` (a 4 KiB scratch database), a second Commit SKP during the wrap, Open `0xa` on `sec_nvm_sp_keymaster` (the keymaster partition, CMAC marker) and LOOKUP_SBAPP `0xe` (a 68806-byte app scratch buffer). Only then did the wrap finish. Each of these got its stock reply layout; the IsCommit, async-commit and scratch-buffer layouts are from `IsCommitOp`, `AsyncCommitOp` and `ScratchBufferOp::execute`.
  - **Shared buffers:** `QSEE_APP_IOC_VMBUF` with `QSEE_APP_VMBUF_HLOS | KEEP` gives a buffer below 4 GiB assigned to {VMID 0x24 RW, HLOS RW} and mmap()able, as stock's ION `sp_mem` heap does.
  - **Polkit:** enrolling from Settings needs a polkit agent, because fprintd's enroll action is `auth_self_keep`. Without `polkit-kde-agent` fprintd answers "Not Authorized".
  - **Driver fixes after the first enroll (libfprint 1.94.100-5):**
    - **No match:** TA status 0x20 ("Identify Fail" in stock's log, apart from BAD_QUALITY 0x27) is a no-match, not a retry. As a retry it kept fprintd's duplicate check, which runs before every enroll, restarting on each touch, so a second finger never got to enroll.
    - **Bio index:** each template's bio index 1..4 is now the lowest one no other finger of the same user holds, taken from the stored prints fprintd passes to that duplicate check, as stock's `get_req_bioindex` picks a free slot. A fifth finger gets FP_DEVICE_ERROR_DATA_FULL.
  - **Lock screen:** Plasma Mobile shows a `fingerprint-symbolic` icon in place of the swipe-up arrow (`BottomIconIndicator.qml`) and no text prompt; that is upstream's design.
  - **The A/B copies on persist:** commits write only the older copy, so the current one is never touched. Never restore an older backup over them: the SPSS's anti-replay value has moved past it.
- **The HAT side, which stock does before enroll:**
  - Control_OP 0x2b generates the pre-enroll challenge.
  - Hat_OP checks version 0, the challenge and an HMAC-SHA256 keyed by what Decap_Key received from the `authhat` TA.
  - The key comes from `skeymast`, through `authhat`.
  - Being decoded in `scratch/fp-ta/hat-key-chain.md` and `gatekeeper-hat.md`.
- **Debug:**
  - `scratch/qsee-log/qsee_log.ko` registers a QSEE log buffer (SCM owner 50, svc 1, cmd 6). TZ accepts it and reports logging unencrypted, but nothing has been written to it so far. It cannot be unloaded.
  - GhidraMCP 2.0 runs headless, one `ghidra-*` server per binary (local MCP scope), with the projects in `scratch/ghidra-projects/`.

## How stock drives the sensor

```
fingerprint@3.0-service -> fingerprint.default.so -> libbauthserver.so
  -> libbauthtzcommon.so -> libQSEEComAPI.so -> /dev/qseecom (downstream qseecom.c)
  -> SCM QSEOS APP_START / APP_SEND -> securefp TA -> secure SPI (TZ-owned QUP)
```

- `libbauthtzcommon.so`, `BAuth_SessionOpen`:
  `QSEECom_start_app(&h, "/vendor/firmware_mnt/image", name, 0x1f4140)`. The name comes from
  the helper at 0x8414, picked by the session type passed to `BAuth_SessionOpen`: types 1, 5,
  6, 7 and 9 get `securefp`, type 3 gets `dualfp`, type 8 gets `securefp` or `dualfp` depending
  on a global flag. There is no `dualfp` image in NON-HLOS `image/`, so `securefp` is the only
  one that can load on this phone. If `/apex/com.samsung.android.biometrics.fingerprint/etc/ta/fpta` is newer it uses
  `QSEECom_start_app_V2` with that file instead. In this firmware the apex payload holds only
  `apex_manifest.pb`, so the preloaded `securefp` is what runs.
- There is no UUID. The legacy path names the app, and the key is `securefp`.
- Shared buffer: 0x1f4140 bytes (about 1.95 MiB).
- One command decoded, `BAuth_Type_Check`: request at sbuf+0, 64 bytes, `u32 opcode = 0x10`,
  `u32 arg` at +4. Reply at sbuf+0x40, 64 bytes, `u32 status` at +0x40, `u32 value` at +0x44.
  The library logs every call as `Call FUNC ID 0x%x`, so other opcodes can be read the same way.
- `BAuth_Get_Ta_Version` never reaches the TA. It compares the preloaded and downloaded file
  versions.
- The same library also opens `authhat` (hardware auth token) and `skeymast` (keymaster) for
  HAT HMAC keys. `securefp` uses `qsee_encapsulate_inter_app_message` and the bulletin board.
  That matters for auth tokens later, not for loading or a first command.

## Inventory

Stock firmware F711NKSSFKZH5, `.cache/fw/`.

| Item | Where | Notes |
|---|---|---|
| `securefp.mdt` + `.b00`-`.b07` | NON-HLOS.bin `image/` | **the TA.** ELF64 AArch64. `check_sensor_gw3x`, `gf_milan_secspi_*`, `sec_tzspi_*`, Goodixlib |
| `fingerpr.mdt` + `.b00`-`.b07` | NON-HLOS.bin `image/` | Qualcomm QFP (qbt ultrasonic) TA, `QFP_BUILD_VERSION`. Not ours |
| `authhat`, `skeymast` | NON-HLOS.bin `image/` | auth token and keymaster TAs used by libbauthtzcommon |
| `tz.mbn`, `hypvm.mbn`, `tz_kg.mbn`, `tz_iccc.mbn`, `tz_hdm.mbn`, `vaultkeeper.mbn`, `km41.mbn`, `uefi_sec.mbn`, `devcfg.mbn` | BL tar | TZ, hypervisor and Samsung TZ services. Already running; nothing to load |
| `libbauthtzcommon.so` | vendor `lib64` | the TA client, 16 `QSEECom_send_cmd` callers |
| `libbauthserver.so`, `libgf_in_system_lib.so` | vendor `lib64` | HAL logic, Goodix HAL helpers |
| `vendor.samsung.hardware.biometrics.fingerprint@3.0-service`, `fingerprint.default.so` | vendor | HIDL service, HAL |
| `libQSEEComAPI.so` | vendor `lib64` | ioctl client of downstream `/dev/qseecom` |
| `qseecomd` | vendor `bin` | listener daemon |
| listener libs | vendor `lib64` | `librpmb`, `libssd`, `libdrmfs`, `libdrmtime`, `libqisl`, `libops`, `libspl`, `libGPreqcancel`, `libhwvault`, `libTrustedUITZ` |
| `ssgtzd`, `libQTEEConnector_*`, `libGPQTEEC_vendor` | vendor | Samsung TZ daemon and the SMCInvoke/GP stacks. Not on the securefp path |
| `fingerprint.ko`, `fingerprint_sysfs.ko` | vendor modules | the stock gw3x driver, source in `.cache/samsung/kernel/drivers/fingerprint/` |

Copies of `securefp.*` and `fingerpr.*` are in `scratch/fp-ta/` (gitignored). To redo it:

```sh
img=.cache/fw/nonhlos/NON-HLOS.bin
mdir -b -i $img ::/image/ | grep '/securefp\.' | while read f; do mcopy -n -i $img "$f" scratch/fp-ta/; done
```

## Listeners

`securefp` has no RPMB, SFS or file system strings. Templates and calibration live on the
HLOS side (`FPBAuthServiceStorage`, `/data/vendor/biometrics`, `/efs/biometrics`), so they
reach the TA as command payloads. It does carry the shared Qualcomm biometric serializer, with
`bio_wait_for_hlos_event` and the "QIS Listener" (`libqisl.so`), next to `check_sensor_qbt2xxx`.
That looks like the qbt (ultrasonic) path, but I haven't proved it from the code.
`qsee_request_service` is also in the TA; a listener request from the TA would go through it.
If APP_START or a command comes back BLOCKED_ON_LISTENER, these are the first suspects.

## What Linux owns

- Rail: S2MPB02 L16 (`VDD_BTP_3P3`).
- Reset GPIO 39 and IRQ GPIO 38. The stock driver drives reset with `gpio_set_value()` and
  requests the IRQ in TZ mode too (`gw3x_common.c`). Stock `lahaina_reserved_gpios` for this
  config is only 52-55 (`!SEC_FACTORY`) and 30-31 (`MST_LDO`). Our DT reserves 4-7, 30-31,
  38-41 and 52-59. The elly DTS is the source for 38-39 ("Goodix FP"). The 0001 comment credits
  4-7, 40-41 and 56-59 to stock `reserved_gpios`, but the stock list doesn't have them; where
  they came from isn't recorded. None of this is verified on the phone. Unreserving a pin
  that TZ does protect fails when the gpiochip registers, so test it on its own.
- `GF_IOC_ENABLE_SPI_CLK` on QCOM only takes a wakelock. The TA claims the SPI pins through
  `qsee_tlmm_*` and runs the QUP clocks itself. Our cmdline already has `clk_ignore_unused`.

## Mainline 7.3.1

- `qcom_scm.c` has QSEECOM version, app lookup and app send. It has no APP_START or SHUTDOWN.
  `qcom_scm_qseecom_call()` `WARN_ON`s INCOMPLETE and BLOCKED_ON_LISTENER and does not handle
  them. Stock sets `qcom,qsee-reentrancy-support = <2>`.
- `qcom_qseecom.c` only registers clients on allowlisted laptops. The probe does not need that
  device.
- `qcomtee` (SMCInvoke) exists. SM8350 speaks the same INVOKE command (stock smcinvoke has no
  `support-legacy_smc`), but it selects `QCOM_TZMEM_MODE_SHMBRIDGE`, which changes every SCM
  buffer path (PAS, rmtfs). The HAL doesn't use it either. Fallback only.
- `QCOM_TZMEM_MODE_GENERIC` stays. Stock registers shm bridges, but mainline never enables
  them in generic mode. My guess is that TZ then takes plain buffers the legacy way. What
  backs it: PAS loads (mpss, slpi, adsp metadata in `qcom_tzmem`) work today in generic mode.
  APP_START itself has not been tried.

## Gates

1. **Listeners.** No storage listener on the load path, from the strings. QIS is open (above).
2. **What mainline needs.** APP_START and SHUTDOWN plus a test client. That is `0040-*`. If the
   TA blocks on a listener, the job grows into porting the listener protocol
   (INCOMPLETE/BLOCKED handling, a listener registration interface), which is a much larger
   job.
3. **Whether stock TZ loads `securefp` from this boot chain.** Only the phone can answer that.
   Facts that bear on it: `securefp` is 64-bit, and stock DT says
   `qcom,commonlib64-loaded-by-uefi` and `qcom,appsbl-qseecom-support`, so the bootloader loads
   cmnlib64 and sets up the apps region. ABL still runs before U-Boot, so that should still
   happen. If APP_START fails, cmnlib64 is the first suspect. KG/ICCC/warranty-bit refusal is
   possible and can't be checked locally.

No Linux SPI driver is possible: the bus belongs to TZ.

## Probe (`patches/linux/0040-*`)

`CONFIG_QCOM_QSEECOM=y` (logs `qseecom: found qseecom with version ...` and
`untested machine, skipping` at boot) and `CONFIG_QCOM_QSEECOM_PROBE=m` are in
`configs/b2q.fragment`. The module `qcom_qseecom_probe` runs once at load:

| `stage=` | does |
|---|---|
| 0 | APP_LOOKUP `securefp` |
| 1 | + APP_START from `<fw_dir>/securefp.mdt` + `.b00`-`.b07` if not loaded |
| 2 | + one command (default opcode 0x10, BAuth_Type_Check), reply hex-dumped |

`fw_dir` defaults to `qcom/sm8350/Samsung/b2q`. It needs the **split** files, not a squashed
`.mbn`: TZ expects the `.mdt` and `.bNN` parts back to back, which is not the
`tools/pil-squash.py` layout. `rmmod` shuts the app down if the probe loaded it. Stage 2 with
the sensor unpowered may get a TA error status back, or may not answer usefully; that is a
guess. A real chip ID needs L16 on and reset high, which comes later.

Cost of a bad stage 1 or 2: if TZ answers INCOMPLETE or BLOCKED_ON_LISTENER, mainline warns and
walks away without answering. QSEE may then keep that request pending, and later QSEECOM calls
may fail or block until a reboot. Plan a reboot window before stage 1.

The `.o` files compile with W=1 and every symbol the probe imports is exported
(`faux_device_create/destroy`, `qcom_tzmem_pool_new/free`, `qcom_tzmem_alloc/free/to_phys`).
The full build of the fresh tree (2026-11-10, all of 0001-0043 applied) links
`qcom_qseecom_probe.ko` through modpost with no warnings.

Device steps, in order, each only when asked:

1. A new image is needed, because `CONFIG_QCOM_QSEECOM=y` is built in. It comes from the
   fresh tree `scratch/linux-fresh/linux-7.3.1` (all of 0001-0043 applied with
   `tools/build-kernel.sh --tree ... --apply`), not from `.cache/linux-7.3.1`, whose patch
   state is mixed. It has to go in together with that tree's modules
   (`make modules_install INSTALL_MOD_PATH=<staging>`, then copy `lib/modules/7.3.1` over),
   since the rootfs modules come from an older build.
2. Copy `scratch/fp-ta/securefp.*` (split files) to `/usr/lib/firmware/qcom/sm8350/Samsung/b2q/`.
3. `modprobe qcom_qseecom_probe stage=0`, read `dmesg`, `rmmod`; then `stage=1`; then
   `stage=2`. Stage 1 is the one that needs the reboot window above.
