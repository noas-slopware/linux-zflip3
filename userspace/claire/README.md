# claire

Sets up the secure-world services that Samsung's fingerprint TA (`securefp`) depends on,
the way the stock Android stack does at boot, over `/dev/qsee-app` (kernel patch 0049):

0. **The SPSS channels and sec_nvm** (stock `spdaemon` and `sec_nvm`): as the secure
   processor's GLINK edge (patch 0055) announces its channels, `sp_kernel` and every
   `sec_nvm_<app>` channel are bound to `rpmsg_chrdev`. Each `sec_nvm_<app>` channel gets
   its own NVM manager (`src/nvm.c`), which loads that app's partition from
   `/mnt/vendor/persist/secnvm` into a buffer shared with the SPSS (VMID 0x24 + HLOS,
   `QSEE_APP_VMBUF_HLOS`) and commits it back to the older of its two copies. It also hands
   out the scratch buffers the SPSS asks for. Once the SPSS's own kernel partition is open
   and committed (NVM_READY), `sp_keymaster` is opened and the steps below run, on a thread
   of their own so the SPSS's requests keep being answered meanwhile.
1. **keymaster64** (resident; ABL loads it): `KM_NEW_CONFIGURE` (0x2116) with stock's OS
   version 15 and patch levels 2026-08 / 2026-08-05, then `KEYMASTER_SPU_INIT` (0x20d) with
   a 0x5000-byte buffer below 4 GiB handed to the secure processor (VMID 0x22,
   `QSEE_APP_VMBUF_KEEP`: it stays theirs until reboot). Stock: the QTI StrongBox HAL and
   Samsung's `init_spu_worker`.
2. **hwvault**: loaded and kept loaded for as long as the service runs. securefp derives
   the key that seals its templates from hwvault (QSEE service 0x89). Its root of trust is
   set from `/var/lib/claire/hwvault.hvr` (`SET_HWVAULT_ROT` 0x271c) or, the first time,
   generated (`GENERATE_HWVAULT_ROT` 0x271b) and saved. Stock: `hermesd`.

Generating the root of trust goes through keymaster64 to the secure processor (SPSS). That
needs QSEE listener 0xb000 (`qcom_spss_listener`, patch 0054) and step 0, and it works:
on 2026-11-10 the root key was generated, and fingerprint enrollment seals its templates.

Never put an older copy of `/mnt/vendor/persist/secnvm` back: the SPSS's anti-replay
value has moved past it.

The decoding behind each step is in `scratch/fp-ta/` (`keymaster64-configure.md`,
`hwvault-service.md`, `spu-path.md`, `sec-nvm.md`) and summarized in `FINGERPRINT.md`.
