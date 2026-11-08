# Current state: 2026-11-08

Galaxy Z Flip3 SM-F711N (b2q), mainline Linux 7.3.1 #55 + our patches, Arch Linux Ports
aarch64 rootfs. Branch `senpai`, ahead of `origin/senpai`, nothing pushed.

## Works on the phone (kernel #55)

| Area | State | Details |
|---|---|---|
| Boot chain | ABL -> U-Boot (`boot`) -> Linux (`recovery`), installed over ssh | working |
| Wi-Fi / BT | QCA6390 over PCIe, ath11k | working |
| USB | gadget + data lines via MAX77705 switch | working |
| GPU | Adreno 660, zap shader | working |
| Display | S6E3HAD main panel, 120/60 Hz modes | working |
| Touch | FTS9CU80F | working |
| RTC | PMK8350, offset in SDAM14 0xbc | working |
| Plasma Mobile | user `mogumo`, PLM autologin + PlaMo lock screen first | working |
| Haptics | PWM driver on GCC GP2 + mainline max77705-haptic, feedbackd | working |
| Fold sensor | gpio80 as SW_LID, closing suspends, opening wakes | working |
| Suspend | s2idle (`mem_sleep_default=s2idle`), PCIe GDSCs in retention | working |
| Fuel gauge | max17042 as max77705-battery, 2 mOhm | working |
| Charger | stock init, BC1.2 currents, AFC 9 V, USB PD 9 V PDO | working |
| Dual cells | S2ASL01 limiters + samsung-dual-battery | working |
| Cellular data | mpss PAS + rmtfs + ModemManager, LG U+ LTE data (IPv6 + CLAT v4) | working |
| SMS over IMS | SIP MESSAGE over b2q-imsd on qmapmux0.3 | send and recv work |

## Open issues and current blocks

### 1. Audio: speakers work (kernel #57, 2026-11-08)
- Speaker sink and stereo mic source come up in PipeWire (HiFi profile).
  Noa confirmed sound on the speaker. Mic capture not yet checked.
- Both CS35L41 amps run stock's Cirrus protection firmware
  (`tools/extract-amp-firmware.sh` -> `/usr/lib/firmware/cirrus/`), loaded via
  `cirrus,subsystem-id = "samsung-b2q"`. Stock gains: speaker device 18 dB
  analog / 817 digital on both amps (dual-speaker), earpiece 2 / 761.
- Per-unit calibration is in `/efs/cirrus/` but EFS is fscrypt-encrypted, so the
  firmware runs uncalibrated (what mainline does when no calibration exists).
- The protection routing is in the HiFi verb, not FixedBootSequence: PipeWire
  never runs boot sequences, and the amps must not play at these gains in bypass.
- Fixed on the way: TDM pins never muxed, a cs35l41-lib hack hiding the amp
  power-up timeout, wrong AFE slot-map bitwidth, receiver/speaker slots swapped,
  amp I2C at 100 kHz (firmware download timed out; stock is 1 MHz), q6afe never
  keeping the LPASS vote handle (every devote failed), the VA macro and LPI
  pinctrl missing for the DMICs.
- Pending deploy: `out/snd-soc-cs35l41-lib.ko.zst` with a 15 ms CSPL mailbox
  window (downstream's); on #57 the receiver DSP missed PAUSE in 5 ms
  ("Failed to set mailbox cmd 1 (status 0)").
- Open: mainline inverts the TDM bit clock at the AFE, stock does not; suspect
  it first if the sound is distorted.

### 2. VoLTE Calls (b2q-imsd)
- Outgoing calls: LG U+ domestic numbers must be formatted as `sip:<number>@lte-lguplus.co.kr;user=phone`. `tel:+82...` returns SIP 404 Not Found from IBCF.
- Incoming calls: Answering previously dropped after 2.3 seconds because `handle_incoming_invite()` in `userspace/imsd/src/sip.c` emitted a redundant call state change (state 2) that caused ModemManager to terminate the call, and `method_answer_call()` in `userspace/imsd/src/imsd.c` omitted `sd_bus_message_read(m, "u", &call_id)`.
- Test audio responder `/root/yurushite_neko.amrwb_frames` in `sip.c` needs removal once call audio is routed.

### 3. MMS Messaging
- Carrier (LG U+ 45006) delivers MMS notifications as multi-part concatenated binary WAP Push SMS (DCS 0x04) from shortcode `0100000004`.
- Raw incoming TPDU must be forwarded over D-Bus as a raw 3GPP PDU hex string to ModemManager (`PduReceived` signal) so ModemManager's native 3GPP assembly can decode the WAP Push notification and allow Spacebar to download media over `qmapmux0.0`.

## Key files and locations

- UCM files (repo): `userspace/rootfs/usr/share/alsa/ucm2/Qualcomm/sm8250/SM-F711N/`
- b2q-imsd source: `userspace/imsd/src/` (`imsd.c`, `sip.c`, `sms.c`, `ims_bearer.c`)
- Audio kernel patches: `patches/linux/0017-*` (TDM + CS35L41), `0018-*`/`0019-*` (VA macro), DT in `0001-*`
- Phone IP: `root@192.168.0.105` (hostname `Love-Me-for-Who-I-Am`)
