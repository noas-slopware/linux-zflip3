# Current state: 2026-11-09

Galaxy Z Flip3 SM-F711N (b2q), mainline Linux 7.3.1 #57 + our patches, Arch Linux Ports
aarch64 rootfs. On the phone: b2q-imsd 0.1.0-16, modemmanager 1.24.2-5 (with
`patches/modemmanager/`), spacebar 6.3.4-4 (with `patches/spacebar/`).

## Works on the phone (kernel #57)

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
| IMS bearer | b2q-ims-bearer: WDS profile 4, IPv6, on qmapmux0.3 at the MTU the network signals (1400) | comes up on boot, retries until the modem is ready |
| IMS registration | b2q-imsd, ISIM AKA, identity read from the ISIM (EF_IMPI/IMPU/DOMAIN) | working |
| SMS | send; receive through a durable inbox, so nothing is lost while ModemManager or the phone is down; network retries stored once | working |
| MMS | receive (WAP Push via ModemManager, download by Spacebar) and send from Spacebar | working |
| VoLTE calls | in and out, on-net and to KT/SKT, AMR-WB or AMR-NB as negotiated; answer, decline, hang up from either side | working |
| Call audio | b2q-ims-audio in the user session bridges imsd and PipeWire; speaker and mic | working, earpiece not yet |

## Open issues and current blocks

### 1. Audio: speakers work (kernel #57, 2026-11-08)
- Speaker sink and stereo mic source come up in PipeWire (HiFi profile).
  Noa confirmed sound on the speaker, and the mic works in VoLTE calls (2026-11-09).
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

### 2. Incoming calls and SMS do not wake the phone
- Measured 2026-11-09 with the lid closed (s2idle): an SMS and a call reached the phone
  only when the lid was opened. The callee side heard normal ringback, and the queued SIP
  MESSAGE and INVITE retransmissions were processed at resume (imsd now stores a retried
  SMS once and treats INVITE retransmissions as one call).
- `1e40000.ipa` is a registered and enabled wakeup source but its event count stays 0:
  the IPA TX_SUSPEND interrupt that should wake the AP when the modem has data never fires.
  Kernel task (IPA/GSI on SM8350); not a userspace wakelock.

### 3. IMS and calls, still open
- ModemManager deletes every rmnet link on its first connect, qmapmux0.3 included. The
  bearer notices and comes back, but with its restart backoff that cost about a minute of
  IMS at boot (registered 85 s after power-on). Fix in ModemManager: delete only its own links.
- DTMF is never sent: ModemManager's requests reach no code that transmits telephone-events.
- In-dialog requests imsd does not answer: re-INVITE / UPDATE session refresh (long calls may
  drop around the refresh), OPTIONS, INFO. Call-ID matching on BYE/CANCEL and full Via lists
  on BYE/MESSAGE replies are missing too.
- Requests above 1200 bytes should go over TCP (RFC 3261 18.1.1); the INVITE is ~1430 bytes
  and goes out IPv6-fragmented over UDP. It works on LG U+, but it is against the spec.
- REGISTER has no retransmission and its refresh timer runs on CLOCK_MONOTONIC, so it does
  not advance during suspend.
- The earpiece: calls play on the speaker; the UCM has no Voice Call profile or earpiece port
  for callaudiod to switch to.

### What outgoing calls needed (for reference)
- Request-URI `tel:<number>;phone-context=lte-lguplus.co.kr` for every number without `+`, the
  stock Samsung IMS stack's rule. `sip:<number>@lte-lguplus.co.kr;user=phone` only worked
  on-net.
- A TTA User-Agent (`TTA-VoLTE/1.0 <model>/<sw> Device_Type/Android_Phone LUC`, TTAK.KO-06.0357):
  without it off-net calls got 404 from LG U+.
- `telephone-event/16000` in the offer next to `/8000`, or the answer falls back to AMR-NB.
- Spacebar needs `Connection: close` on MMSC requests, or LG U+ answers every M-Send.req with
  "format corrupt".

## Key files and locations

- UCM files (repo): `userspace/rootfs/usr/share/alsa/ucm2/Qualcomm/sm8250/SM-F711N/`
- b2q-imsd source: `userspace/imsd/src/` (`imsd.c`, `sip.c`, `sms.c`, `aka.c`, `inbox.c`,
  `codec.c`, `audio.c`; `ims_bearer.c` and `ims_audio.c` are the bearer and the audio bridge)
- MT-SMS inbox: `/var/lib/b2q-imsd/inbox/` on the phone; call audio socket `/run/b2q-imsd/audio.sock`
- Audio kernel patches: `patches/linux/0017-*` (TDM + CS35L41), `0018-*`/`0019-*` (VA macro), DT in `0001-*`
- Phone IP: `root@192.168.0.105` (hostname `Love-Me-for-Who-I-Am`)
