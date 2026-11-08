# Cellular device tree check: modem, MPSS and IPA

Source comparison of Samsung's b2q device tree against the mainline 7.3.1 board
description, for the cellular parts: the reserved-memory carveouts the modem and IPA
firmware live in, the PIL modem node, the IPA node and the SMP2P channels that connect
them.

Nothing was run on the phone. All of this is local: Samsung's decompiled base device tree
(`/tmp/opencode/vb0.dts`, from `boot.img` of the stock firmware) plus its board overlay
(`evidence/raw/dtbo/entry.3.dts`), and the mainline tree in `.cache/linux-7.3.1` together
with the DTB we build (`arch/arm64/boot/dts/qcom/sm8350-samsung-b2q.dtb`, decompiled to
`/tmp/opencode/b2q-current.dts`).

Samsung ships the board values in the DTBO, not in the base DTB, so the *effective* stock
configuration is base + overlay, and the overlay wins on every `reg`. All seven DTBO
entries are identical for these properties (`entry.0` through `entry.6`, all with `id = 0`),
so which one the bootloader picks does not matter.

## 1. Reserved memory, 0x80000000 to 0xa0000000

"Stock" below is the effective value (base DTB overridden by the DTBO fragment named in
parentheses). "Ours" is from the built DTB, so it is the merged tree after every
`/delete-node/` and override in `sm8350-samsung-b2q.dts`. Everything is `no-map`;
no region in this range uses `shared-dma-pool`, `reusable` or a `size`/`alignment`
property.

| region (our node) | ours base / size | end | provenance in ours | stock effective | match |
|---|---|---|---|---|---|
| hyp `memory@80000000` | `0x80000000` / `0x600000` | `0x80600000` | dtsi default | `0x80000000` / `0x600000` | yes |
| xbl_aop `memory@80700000` | `0x80700000` / `0x160000` | `0x80860000` | dtsi default | same | yes |
| cmd_db `memory@80860000` | `0x80860000` / `0x20000` | `0x80880000` | dtsi default | same | yes |
| xbl_uefi_log `memory@80880000` | `0x80880000` / `0x14000` | `0x80894000` | dtsi default | same | yes |
| smem `smem@80900000` | `0x80900000` / `0x200000` | `0x80b00000` | dtsi default | same | yes |
| cpucp_fw `memory@80b00000` | `0x80b00000` / `0x100000` | `0x80c00000` | dtsi default | same | yes |
| cdsp_secure_heap `memory@80c00000` | `0x80c00000` / `0x600000` | `0x81200000` | **b2q redefined** (dtsi: `0x4600000`) | `0x80c00000` / `0x600000` (frag 157) | yes |
| pil_adsp_mem `memory@85200000` | `0x85200000` / `0x3000000` | `0x88200000` | **b2q redefined** (dtsi: `0x86100000` / `0x2100000`) | `0x85200000` / `0x3000000` (frag 158) | yes |
| pil_cdsp_mem `memory@89700000` | `0x89700000` / `0x1e00000` | `0x8b500000` | dtsi default | same (frag 160) | yes |
| pil_ipa_fw_mem `memory@8b500000` | `0x8b500000` / `0x10000` | `0x8b510000` | dtsi default | same (frag 161) | yes |
| pil_ipa_gsi_mem `memory@8b510000` | `0x8b510000` / `0xa000` | `0x8b51a000` | dtsi default | same (frag 162) | yes |
| pil_gpu_mem `memory@8b51a000` | `0x8b51a000` / `0x2000` | `0x8b51c000` | dtsi default | same (frag 163) | yes |
| pil_spss_mem `memory@8b51c000` | `0x8b51c000` / `0x100000` | `0x8b61c000` | **b2q redefined** (dtsi: `0x8b600000` / `0x100000`) | `0x8b51c000` / `0x100000` (frag 164) | yes |
| pil_modem_mem `memory@8b800000` | `0x8b800000` / `0xf600000` | `0x9ae00000` | **b2q redefined** (dtsi: `0x10000000`) | `0x8b800000` / `0xf600000` (frag 165) | yes |
| rmtfs + camera `memory@9b800000` | `0x9b800000` / `0x500000` | `0x9bd00000` | dtsi `rmtfs_mem`, reg taken from b2q's `pil_camera_mem` | camera `0x9b800000` / `0x500000` (frag 166); stock has no rmtfs carveout | see below |
| pil_video_mem `memory@9bd00000` | `0x9bd00000` / `0x500000` | `0x9c200000` | **b2q redefined** (dtsi: `0x85700000`) | `0x9bd00000` / `0x500000` (frag 167) | yes |
| pil_cvp_mem `memory@9c200000` | `0x9c200000` / `0x500000` | `0x9c700000` | **b2q redefined** (dtsi: `0x85c00000`) | `0x9c200000` / `0x500000` (frag 168) | yes |
| pil_slpi_mem `memory@9c700000` | `0x9c700000` / `0x1600000` | `0x9dd00000` | **b2q redefined** (dtsi: `0x88200000` / `0x1500000`) | `0x9c700000` / `0x1600000` (frag 159) | yes |

The gaps are the same as stock's: `0x80600000` to `0x80700000`, `0x80894000` to
`0x80900000`, `0x81200000` to `0x85200000` (stock's overlay shrinks `cdsp_secure_heap`
the same way), `0x8b61c000` to `0x8b800000` and `0x9ae00000` to `0x9b800000`. The ten
megabytes between the end of modem memory and the camera carveout is not reserved in
either tree.

Stock also has `hdm_region@9FB00000` (`0x9fb00000` / `0x1000`, `removed-dma-pool`,
`no-map`, fragment 155). We do not carry it: nothing in mainline binds that compatible and
it overlaps nothing, so it does not matter. Its sibling `0xa0001000` / `0x1000` is above
the range asked about.

### Is `pil_modem_mem` correct?

Yes. Stock's base DTB has `0x8b800000` / `0x10000000` (256 MiB, ending exactly at
`0x9b800000`), but fragment 165 of the board overlay shrinks it to `0x8b800000` /
`0xf600000`. Our value is the shrunk one, 246 MiB ending at `0x9ae00000`, which is what
the phone actually runs (`evidence/device/20261106-mainline-first-boot/dmesg.txt:22`
reports the same 251904 KiB region). Keeping the dtsi's 256 MiB would collide with
`rmtfs_mem` at `0x9b800000`, so the redefinition is required, not cosmetic.

### Are the dtsi-default `pil_ipa_fw_mem` and `pil_ipa_gsi_mem` correct?

Yes, both are stock's values to the byte, with no redefinition needed:
`pil_ipa_fw_mem` `0x8b500000` / `0x10000` (64 KiB, ends `0x8b510000`), `pil_ipa_gsi_mem`
`0x8b510000` / `0xa000` (40 KiB, ends `0x8b51a000`). They sit immediately after
`pil_cdsp_mem` and slot in before `pil_gpu_mem` and `pil_spss_mem` without touching
either. Stock's overlay re-states both values unchanged (fragments 161 and 162).

One size check that can be made locally: mainline remaps the whole 64 KiB region and
loads the firmware into it (`ipa_firmware_load()` in `drivers/net/ipa/ipa_main.c`), and
our extracted `ipa_fws.mbn` is 37,832 bytes, so it fits with room to spare. Our
`modem.mbn` is 88,596,620 bytes against the 246 MiB carveout.

### One thing our tree gets wrong at `0x9b800000`

`sm8350-samsung-b2q.dts` deletes the three dtsi nodes at `0x85200000`, `0x85700000` and
`0x85c00000` and re-adds camera, video and CVP at Samsung's addresses. Video and CVP land
on free space, but the camera node is declared as `pil_camera_mem: memory@9b800000`, and
the dtsi already has `rmtfs_mem: memory@9b800000` at the same unit address. DTC merges
the two: the result is a single node that keeps the dtsi's `compatible = "qcom,rmtfs-mem"`,
`qcom,client-id` and `qcom,vmid`, takes b2q's `reg` (so the rmtfs carveout grows from
`0x280000` to `0x500000`), and gains no phandle because nothing references
`pil_camera_mem`. The built DTB has one node there, and it is the rmtfs one.

So the camera carveout does not exist in our tree; it was swallowed by rmtfs. This is
currently inert, camera is not enabled on b2q, which is also why the node got no phandle.
It does mean that if camera support is added later it will be pointed at rmtfs memory, and
the modem's rmtfs service is being handed a 5 MiB buffer instead of mainline's 2.5 MiB.
Neither breaks anything today. Any fix has to either move one of the two to a free
address (the gap `0x9ae00000` to `0x9b800000` or the space above `0x9dd00000` is free in
both trees) or drop the camera node, and that is a decision about where rmtfs should
live, not about the modem.

There is no stock carveout to compare the rmtfs size against: Samsung exposes rmtfs as a
`qcom,sharedmem-uio` device instead (`vb0.dts:8964`, `reg = <0x0 0x280000>`, `reg-names =
"rmtfs"`), so `0x280000` in the dtsi is mainline's own choice and the `0x500000` we ended
up with is stock's camera size, arrived at by accident. Both boot logs already show the
merged region: `dmesg.txt:23` reports 5120 KiB at `0x9b800000`.

## 2. PIL modem node

Stock is `pil_modem: qcom,mss@8a800000` in `vb0.dts:10214`, `compatible =
"qcom,pil-tz-generic"`, `reg = <0x4080000 0x100>`. Ours is `mpss: remoteproc@4080000`
from `sm8350.dtsi:2227` with `&mpss` in the board file only setting `status = "okay"` and
`firmware-name`. Same base address, `0x04080000`.

| property | stock | mainline `mpss` | comment |
|---|---|---|---|
| `reg` | `0x4080000` / `0x100` | `0x04080000` / `0x10000` | same base; mainline maps the whole 64 KiB bank, harmless |
| `compatible` | `qcom,pil-tz-generic` | `qcom,sm8350-mpss-pas` | selects `mpss_resource_init` |
| `clocks` / `clock-names` | `<&rpmhcc 0>` / `xo` | `<&rpmhcc RPMH_CXO_CLK>` / `xo` | same clock |
| `power` | `vdd_cx-supply`, `vdd_mss-supply`, `qcom,proxy-reg-names = "vdd_cx","vdd_mss"`, `qcom,vdd_*uV-uA = <0x180 0x186a0>` | `power-domains = <&rpmhpd CX>, <&rpmhpd MSS>`, `power-domain-names = "cx","mss"` | same two rails, mainline expresses them as RPMh power domains; the driver uses the names `cx`/`mss` from `mpss_resource_init.proxy_pd_names` |
| `interconnects` | `<&mc_virt 3 &mc_virt 0x200>` | `<&mc_virt MASTER_LLCC 0 &mc_virt SLAVE_EBI1 0>` | same LLCC to EBI1 vote; the ids are different numbering schemes (mainline is 0 / 1 in `qcom,sm8350.h`), so the numbers cannot be compared directly |
| `memory-region` | `<&pil_modem_mem>` | `<&pil_modem_mem>` | identical |
| `firmware-name` | `"modem"` | dtsi has none, b2q sets `qcom/sm8350/Samsung/b2q/modem.mbn` | name only; mainline needs the full path for `request_firmware` |
| `qcom,pas-id` | `4` | none in DT | `mpss_resource_init.pas_id = 4` |
| `qcom,smem-id` | `0x1a5` | none in DT | `crash_reason_smem = 421` = `0x1a5` |
| `qcom,minidump-id`, `qcom,aux-minidump-ids` | `3`, `4` | `minidump_id = 3`; no aux list | the auxiliary ids are a downstream list of extra segments to dump, mainline has no counterpart |
| `qcom,sysmon-id` | `0` | none in DT | `qcom_add_sysmon_subdev()` uses `sysmon_name = "modem"` |
| `qcom,ssctl-instance-id` | `0x12` | none in DT | `ssctl_id = 0x12` |
| `qcom,signal-aop` | present | no equivalent | downstream AOP signalling only |
| `qcom,complete-ramdump` | present | no equivalent | downstream ramdump handling only |
| `qcom,proxy-timeout-ms` | `0x2710` (10 s) | no equivalent, hardcoded 5 s | `qcom_q6v5.c:244` waits `5 * HZ` for stop-ack; stock allows 10 s |
| `interrupts` | GIC SPI 264 level-high, then SMP2P entries 0, 2, 1, 3, 7 | GIC SPI 264 edge-rising, then the same entries 0, 1, 2, 3, 7 (via `&smp2p_modem_in`) | same six signals, see below for the name and order mapping |
| interrupt names | `qcom,wdog`, `qcom,err-fatal`, `qcom,proxy-unvote`, `qcom,err-ready`, `qcom,stop-ack`, `qcom,shutdown-ack` | `wdog`, `fatal`, `ready`, `handover`, `stop-ack`, `shutdown-ack` | one-to-one: stock's `proxy-unvote` is entry 2, which is mainline's `handover`; the `qcom,` prefix on names is downstream style |
| `qcom,smem-states` | `<&modem_smp2p_out 0>`, name `qcom,force-stop` | `<&smp2p_modem_out 0>`, name `stop` | same entry, different label |
| `mboxes` / QMP | `<&qmp_aop 0>`, `mbox-names = "mss-pil"` | `qcom,qmp = <&aoss_qmp>` | same AOP QMP channel, stock reaches it as an mbox and mainline as a phandle |
| glink transport | not in this node (downstream has separate `qcom,glink-mailbox` nodes) | `glink-edge` child with `<&ipcc IPCC_CLIENT_MPSS IPCC_MPROC_SIGNAL_GLINK_QMP>` | mainline keeps the modem's glink channel inside the remoteproc node |

Nothing the `qcom_q6v5_pas` driver reads is missing. It takes `pas_id`, `crash_reason_smem`,
`minidump_id`, `ssctl_id`, `sysmon_name`, `auto_boot` and the proxy power domain names
from the per-compatible descriptor (`drivers/remoteproc/qcom_q6v5_pas.c:1336`), so the
`qcom,sysmon-id` / `qcom,minidump-id` / `qcom,ssctl-instance-id` / `qcom,smem-id` block in
stock's node is redundant on mainline, and all of its values agree with ours.

One behavioural difference worth knowing: `auto_boot` is false on both sides. Stock has no
autoboot either, so the modem is only started when something explicitly starts it (in
practice the IPA driver doing `rproc_boot`, or `echo start > .../state`). Matching stock
means do not expect the modem to come up on its own at boot.

## 3. IPA node

Stock is `ipa_hw: qcom,ipa@1e00000` in `vb0.dts:10349`, `compatible = "qcom,ipa"`, plus
a separate `qcom,ipa_fws` PIL node at `vb0.dts:10341`. Ours is `ipa: ipa@1e40000` from
`sm8350.dtsi:1836` with `&ipa` in the board file setting `status` and `firmware-name`.

| property | stock | mainline | comment |
|---|---|---|---|
| `reg` | `0x1e00000` / `0x84000` as `ipa-base`, `0x1e04000` / `0x23000` as `gsi-base` | `0x1e40000` / `0x8000` as `ipa-reg`, `0x1e50000` / `0x4b20` as `ipa-shared`, `0x1e04000` / `0x23000` as `gsi` | GSI window identical. Stock's `ipa-base` is one flat 528 KiB map starting 64 KiB lower; mainline splits the register block into `ipa-reg` and `ipa-shared`. Both cover the registers the driver touches |
| `interrupts` `ipa` | GIC SPI **654**, level-high | GIC SPI **655**, edge-rising | see below |
| `interrupts` `gsi` | GIC SPI 432, level-high | GIC SPI 432, level-high | identical |
| clock | `<&rpmhcc 0x16>`, name `core_clk` | `<&rpmhcc RPMH_IPA_CLK>`, name `core` | same clock; downstream and mainline number the RPMh clocks differently (`RPMH_IPA_CLK` is 12 in the mainline header) |
| `iommus` | `<&apps_smmu 0x5c0>, <&apps_smmu 0x5c2>` | same | same SID masks |
| `qcom,ipa-hw-ver` | `0x13` | none; `compatible = "qcom,sm8350-ipa"` selects `ipa_data_v4_9` | same hardware class |
| `qcom,gsi-loader` | none | `"self"` | see the firmware section |
| `memory-region` | none on the IPA node itself | `<&pil_ipa_fw_mem>` | stock loads IPA firmware through the separate `qcom,ipa_fws` node |
| `sram` | none; the AP SMMU context bank has `qcom,additional-mapping = <0x146bd000 0x146bd000 0x2000>` | `<&ipa_modem_tables>` = imem `0x14680000` + `0x3d000`, `0x2000` | the same IMEM window `0x146bd000` / `0x2000`. `ipa_data_v4_9` has `imem_addr 0x146bd000`, `imem_size 0x2000`, `smem_size 0x9000`, and stock's `qcom,ipa-q6-smem-size = 0x9000` agrees |
| smem states | via `qcom,smp2p_map_ipa_1_out` child, `<&smp2p_ipa_1_out 0>` (bit 0 of the word) | `<&ipa_smp2p_out 0>, <&ipa_smp2p_out 1>` named `ipa-clock-enabled-valid`, `ipa-clock-enabled` | same entry, mainline addresses the two bits directly |
| clock/interrupt handshake | `qcom,smp2p_map_ipa_1_in` child, `<&smp2p_ipa_1_in 0>` (bit 0) | `<&ipa_smp2p_in 0>`, `<&ipa_smp2p_in 1>` as `ipa-clock-query`, `ipa-setup-ready` | same smp2p entry ("ipa"), same two modem-triggered signals |
| interconnects | 3 paths (`ipa_to_llcc`, `llcc_to_ebi1`, `appss_to_ipa`) with downstream bus vectors | 2 paths (`memory`, `config`) | mainline uses the interconnect framework's own scaling |
| feature flags | ~25 downstream flags (`qcom,ipa-wdi3-over-gsi`, `qcom,use-ipa-tethering-bridge`, holb monitor, ring sizes, ...) | none | all of these are decisions the mainline driver makes itself; the relevant data comes from `ipa_data_v4_9` |
| SMMU child nodes | `ipa_smmu_ap`, `ipa_smmu_wlan`, `ipa_smmu_uc`, `ipa_smmu_11ad` | none | mainline registers its own context banks from `iommus` |
| `mboxes` / QMP | `<&qmp_aop 0>` | `qcom,qmp = <&aoss_qmp>` | same AOP QMP channel that the driver uses in `ipa_power.c` |

### The IPA interrupt number

This is the one real discrepancy in the cellular block. Stock uses GIC SPI 654, and both
stock dumps agree on it (`vb0.dts:10354`, `evidence/raw/dts/vendor_boot.dts:10354`).
Mainline sm8350 uses 655 (`sm8350.dtsi:1848`), and upstream sc7280 in `kodiak.dtsi:2627`
uses 654. The GSI interrupt, 432, matches everywhere. Upstream does enable sm8350 IPA on
HDK, MTP and Surface Duo 2, so 655 is not untried code, but the two trees cannot both be
right about the same GIC line, and a difference of exactly one on an adjacent block is the
shape of an off-by-one.

It cannot be settled locally. What the logs do show is that it has not been exercised on
this phone yet: neither `evidence/device/20261106-mainline-first-boot` nor
`evidence/device/20261106-product-boot` contains `IPA driver initialized`
(`ipa_main.c:893`), and the interconnect providers are still printing `sync_state()
pending due to 1e40000.ipa` later in both, so IPA never finished probing at all. If a
future boot fails at interrupt request, or IPA comes up and never sees an interrupt, 654 is
the first thing to try, and the fix belongs in `sm8350.dtsi`, not in the board file.

The trigger type also differs (stock level-high, mainline edge-rising), but that one is
upstream's convention for the IPA interrupt on every SoC (`sdm845`, `sc7180`, `kodiak` all
use `IRQ_TYPE_EDGE_RISING` for it while GSI is level-high), so it is not an sm8350
mistake.

### Firmware loading: two nodes become one

Stock splits IPA firmware into a separate `qcom,ipa_fws` node: `compatible =
"qcom,pil-tz-generic"`, `qcom,pas-id = 0x0f`, `qcom,firmware-name = "ipa_fws"`,
`qcom,pil-force-shutdown`, `memory-region = <&pil_ipa_gsi_mem>`. Note which region that
is: the 40 KiB GSI carveout, not `pil_ipa_fw_mem`. Nothing in stock's tree references the
64 KiB `pil_ipa_fw_mem` at all, its phandle appears exactly once, at its own definition.

Mainline has no such node. The IPA driver loads the firmware itself: `memory-region =
<&pil_ipa_fw_mem>` on the IPA node, `qcom,gsi-loader = "self"`, and `ipa_firmware_load()`
calls `qcom_mdt_load()` and `qcom_pas_auth_and_reset()` with `IPA_PAS_ID` 15, which is the
same `0x0f` PAS id stock gives its separate node. So the region that stock leaves dead is
the one we actually use, the PAS id matches, and the extracted 37,832 byte `ipa_fws.mbn`
fits the 64 KiB region. The one thing to watch is that mainline's `firmware-name` path is
`qcom/sm8350/Samsung/b2q/ipa_fws.mbn` while stock's is the bare `"ipa_fws"`; ours matches
the file we install in `out/firmware`.

## 4. SMP2P channels

All of these hang off `qcom,smp2p-modem` (`qcom,smem = <435>, <428>`, IPCC client 2
signal 2), which both trees configure identically. Only the node names and labels differ,
never the entry names.

| what | stock `vb0.dts:11530` | mainline `sm8350.dtsi:606` |
|---|---|---|
| parent node | `qcom,smp2p-modem` | `smp2p-modem` |
| `qcom,smem` | `<0x1b3 0x1ac>` | `<435>, <428>` (same values) |
| interrupt | `interrupt-parent = <&ipcc_mproc>` + `interrupts = <2 2 1>` | `interrupts-extended = <&ipcc IPCC_CLIENT_MPSS IPCC_MPROC_SIGNAL_SMP2P IRQ_TYPE_EDGE_RISING>` (client 2, signal 2) |
| AP to modem state | `modem_smp2p_out: master-kernel`, entry `"master-kernel"`, `#qcom,smem-state-cells = <1>` | `smp2p_modem_out: master-kernel`, entry `"master-kernel"`, same cells |
| modem to AP interrupt | `modem_smp2p_in: slave-kernel`, entry `"slave-kernel"`, `interrupt-controller`, `#interrupt-cells = <2>` | `smp2p_modem_in: slave-kernel`, entry `"slave-kernel"`, same |
| IPA AP to modem state | `smp2p_ipa_1_out: qcom,smp2p-ipa-1-out`, entry `"ipa"`, `#qcom,smem-state-cells = <1>` | `ipa_smp2p_out: ipa-ap-to-modem`, entry `"ipa"`, same cells |
| IPA modem to AP interrupt | `smp2p_ipa_1_in: qcom,smp2p-ipa-1-in`, entry `"ipa"`, `interrupt-controller`, `#interrupt-cells = <2>` | `ipa_smp2p_in: ipa-modem-to-ap`, entry `"ipa"`, same |

So `ipa_smp2p_in` / `ipa_smp2p_out` in `sm8350.dtsi` are the same two channels stock calls
`smp2p_ipa_1_in` / `smp2p_ipa_1_out`, with the same `qcom,entry-name = "ipa"` on both
sides. Entry names are what the firmware and `qcom_smem_state` / `smp2p` match on, so
these are compatible; only the labels and node names differ (`ipa-ap-to-modem` and
`ipa-modem-to-ap` against `qcom,smp2p-ipa-1-out` and `qcom,smp2p-ipa-1-in`). Likewise
`smp2p_modem_in` / `smp2p_modem_out` against `modem_smp2p_in` / `modem_smp2p_out`.

The one asymmetry between the two trees is how they address the channel. Downstream goes
through the `qcom,smp2p-map-ipa-1-out` / `-in` wrapper nodes, which take the whole 32-bit
word at bit 0 and shift internally. Mainline addresses the bits directly: `<&ipa_smp2p_out
0>` and `<&ipa_smp2p_out 1>` are bit 0 (`ipa-clock-enabled-valid`) and bit 1
(`ipa-clock-enabled`) of the same `"ipa"` state entry, and `<&ipa_smp2p_in 0>` / `1` are the
two modem-triggered interrupts (`ipa-clock-query` and `ipa-setup-ready`), as described in
`drivers/net/ipa/ipa_smp2p.c`. Same channel and same entry names throughout, so nothing is
missing from the DT.

## Summary

* Stock modem carveout: `0x8b800000` / `0xf600000` (246 MiB, ends `0x9ae00000`), which is
  what we have. The base DTB alone says `0x10000000`; the board overlay shrinks it and
  ours has to keep the shrunk value, otherwise it runs into `rmtfs_mem`.
* Stock IPA firmware regions: `pil_ipa_fw_mem` `0x8b500000` / `0x10000`, `pil_ipa_gsi_mem`
  `0x8b510000` / `0xa000`, both identical to the mainline dtsi defaults we inherit.
* Regions our DTS gets wrong in this range: none of the cellular ones. The only wrong
  thing at `0x9b800000` is not cellular: our `pil_camera_mem` label collides with the dtsi
  `rmtfs_mem` node at the same unit address, so the camera carveout is really the rmtfs
  node with a doubled size. Harmless until camera is enabled.
* One suspect outside the board file: `sm8350.dtsi`'s IPA interrupt is GIC SPI 655 while
  both stock dumps and upstream sc7280 say 654. Neither boot log gets far enough to test
  it. Unverifiable without the phone.
