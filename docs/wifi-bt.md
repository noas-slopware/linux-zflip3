# Wi-Fi and Bluetooth

The combo chip is a **Qualcomm QCA6390** (Hastings), not a WCN685x:

- The vendor partition only carries Hastings firmware: `firmware/qca6390/amss20.bin`
  reports `WLAN.HST.1.0.1.r1-01571-QCAHSTSWPL_SILICONZ-1`.
- Samsung's `firmware/bt_nvm_loading.xml` says `<Chipset value="QCA6390"/>`.
- On mainline, the PCIe function enumerates as `17cb:1101` (`ath11k_pci: qca6390 hw2.0`),
  and Bluetooth reports `QCA SOC Version 0x400a0200`, ROM `0x200`.

The stock DT calls the node `qcom,cnss-qca6490`, which is misleading.

## Wiring (stock DT, board-id 08)

| | |
|---|---|
| WLAN_EN | gpio64 |
| BT_EN | gpio65 |
| SW_CTRL | gpio27 (overlay; the base DT says gpio153) |
| FEM select | gpio3, read by Samsung's cnss2; low on this unit |
| Wi-Fi | PCIe0: PERST gpio94, CLKREQ gpio95, WAKE gpio96; PHY on L5B 0.88 V, L6B 1.2 V |
| Bluetooth | SE18 4-wire UART: gpio68 CTS, 69 RTS, 70 TX, 71 RX |
| aon, dig | S11B (1.012 V requested) |
| io | S10B 1.8 V |
| rfa 1.3 | S12B (1.35 V requested) |
| rfa 1.9 | PM8350C S1 (1.984 V requested) |
| antenna switch | PMR735A L7 2.8 V (not a QCA6390 rail) |

The board DTS (`patches/linux/0001`) describes this the way the mainline RB5 does: a
`qcom,qca6390-pmu` power unit, `wifi@0` (`pci17cb,1101`) under the PCIe0 root port, and
`qcom,qca6390-bt` on `uart18`.

The DT needs a root `compatible`. Without one, `of_have_populated_dt()` is false, the
regulator core refuses dummy supplies, and qcom-pcie fails on its optional `vdda` supply
(`incomplete constraints, dummy supplies not allowed (id=vdda)`), so ath11k never probes.

## Firmware

| file | from |
|---|---|
| `ath11k/QCA6390/hw2.0/amss.bin`, `m3.bin` | linux-firmware-atheros |
| `updates/ath11k/QCA6390/hw2.0/board-2.bin` | Samsung `vendor:/firmware/qca6390/bdwlan.elf` |
| `updates/qca/htbtfw20.tlv`, `htnv20.bin` | Samsung `vendor:/firmware/` |

`tools/extract-wcn-firmware.sh AP_*.tar.md5` pulls the Samsung files out of the AP tar
(super, then vendor, then debugfs) into `out/firmware`, and `tools/build-rootfs.sh`
copies that tree into the rootfs. Everything Samsung goes under
`/usr/lib/firmware/updates`, which the loader searches first, so no package file is
overwritten.

Which board file: Samsung's `cnss2.ko` names it from the board id and adds `.nxp` when
the FEM select pin is high. ath11k reports `board_id 0xff`, and gpio3 reads low with the
stock no-bias setting, so the file is plain `bdwlan.elf`.

ath11k looks up board data by name. linux-firmware's QCA6390 `board-2.bin` already has a
generic `bus=pci,qmi-chip-id=0,qmi-board-id=255` entry, which would win over a
`board.bin`. So `tools/ath11k-board2.py` packs `bdwlan.elf` into our own `board-2.bin`
twice: under the DT's calibration variant (`variant=Samsung_Galaxy_Z_Flip3`) and under
the generic name. To check that it really is used: with a `board-2.bin` that has neither
name, ath11k fails with `failed to fetch board data for bus=pci,qmi-chip-id=0,qmi-board-id=255`.

## Addresses

The chip has no factory addresses. Samsung keeps them on `efs` (sda6):
`bluetooth/bt_addr` and `wifi/.mac.info`.

- `/usr/lib/b2q/efs-addr bt|wifi` mounts efs read-only with `noload`, prints the
  address and unmounts it again.
- Bluetooth: without a public address, `hci0` stays unconfigured and bluetoothd does not
  see it ("No default controller available"). A udev rule starts `b2q-bt-addr.service`,
  which runs `btmgmt --index 0 public-addr` before `bluetooth.service`. hci0 registers
  about a second before its firmware download finishes and it accepts the address, so
  the first attempt fails with `Invalid Index` and the service retries.
- Wi-Fi: the permanent address ath11k reports is a Qualcomm placeholder (`00:03:7f:…`).
  `b2q-wifi-mac.service` writes `/run/NetworkManager/conf.d/10-b2q-wifi-mac.conf` with
  `wifi.cloned-mac-address` for `driver:ath11k_pci` before NetworkManager starts.

## Kernel

Built in or as modules by `configs/nura-sm8350.config`: `PCIE_QCOM`, `PCI_PWRCTRL_PWRSEQ`,
`POWER_SEQUENCING_QCOM_WCN`, `ATH11K_PCI`, `BT_HCIUART_QCA`. `configs/b2q.fragment` adds
`BT_LE`, `BT_RFCOMM` and `BT_BNEP`, which the Nura config leaves out.

## Rootfs

`ROOTFS_PACKAGES` has `networkmanager`, `linux-firmware-atheros`, `bluez`, `bluez-utils`
and `iw`. NetworkManager leaves `usb0` to systemd-networkd
(`/etc/NetworkManager/conf.d/10-b2q-usb0.conf`), or it would take 172.16.42.1 away.

## Connecting

WPA2-Enterprise with EAP-TTLS/PAP, from a shell on the phone:

```sh
nmtui
# Edit a connection -> Add -> Wi-Fi
#   SSID: <network>, Security: WPA & WPA2 Enterprise
#   Authentication: TTLS, Inner authentication: PAP
#   Username/Password; CA certificate as your network requires
```

or in one line:

```sh
nmcli con add type wifi ifname wlp1s0 con-name <name> ssid '<network>' \
  wifi-sec.key-mgmt wpa-eap 802-1x.eap ttls 802-1x.phase2-auth pap \
  802-1x.identity '<user>' 802-1x.password '<password>'
nmcli con up <name>
```

Bluetooth: `bluetoothctl`, then `scan on`, `pair <addr>`, `connect <addr>`.
