# Handover prompt: 2026-11-08 (Audio, VoLTE, MMS)

Paste everything below the line into a new session.

---

You are continuing the mainline Linux port on Noa's Samsung Galaxy Z Flip3 (SM-F711N, `b2q`, SM8350), repo `/home/yuifunami/linux-zflip3`, branch `senpai`. Before doing anything, read `AGENTS.md` and `STATE.md`.

Strict rule: ZERO em dashes across all code, comments, diffs, and chat. No ChatGPTese, direct and technical.

Current focus:
1. Audio: install kernel and rootfs UCM built on 2026-11-08 and check speakers, earpiece and mic (see STATE.md section 1).
2. Fix VoLTE call handling in `b2q-imsd` (answer call drop, SIP URI formatting for LG U+, remove test audio autoresponder).
3. Fix MMS delivery (forward raw binary WAP Push 3GPP PDU to ModemManager so Spacebar auto-downloads media).

## 1. Audio
See STATE.md section 1. Kernel side: patches 0001 (DT), 0017, 0018, 0019 and
`CONFIG_PINCTRL_SC7280_LPASS_LPI=y`; UCM in `userspace/rootfs/usr/share/alsa/ucm2/`.
Nothing of this has run on the phone yet.

## 2. VoLTE Calls (b2q-imsd)
- Dialing: LG U+ domestic numbers require `sip:<number>@lte-lguplus.co.kr;user=phone`. Using `tel:+82...` returns SIP 404 Not Found from IBCF.
- Incoming calls: Answering previously dropped after 2.3 seconds because:
  - `handle_incoming_invite()` in `userspace/imsd/src/sip.c` redundantly emitted `imsd_emit_call_state_changed(..., 2, 0)` which triggered ModemManager to terminate the call.
  - `method_answer_call()` in `userspace/imsd/src/imsd.c` omitted `sd_bus_message_read(m, "u", &call_id)`.
- Test responder: `/root/yurushite_neko.amrwb_frames` in `sip.c` (`on_rtp_tx_timer`) needs to be removed in favor of proper PCM capture or silence.

## 3. MMS Messaging
- Network: LG U+ delivers MMS notifications via multi-part concatenated binary SMS (DCS 0x04) from shortcode `0100000004`.
- Current issue: b2q-imsd decodes SMS text and drops raw WAP Push binary data, printing `[binary DCS 0x04...]` instead of feeding the PDU to Spacebar.
- Fix:
  - In `b2q-imsd` (`userspace/imsd/src/sip.c`): Format incoming RP-DATA TPDU as raw hex PDU string (`"00" + hex(tpdu)`) and emit over D-Bus signal `PduReceived`.
  - In ModemManager: Subscribe to `PduReceived` and forward to `mm_sms_part_3gpp_new_from_pdu()` and `mm_iface_modem_messaging_take_part()` so MM handles concatenation and Spacebar auto-downloads MMS media over `qmapmux0.0`.

## Workflow & Device
- Phone: `root@192.168.0.105` (hostname `Love-Me-for-Who-I-Am`, user `mogumo`, UID 1000).
- Test SIM: LG U+ (`010XXXXXXXX`). Noa's test phone: KT Fold8 (`010YYYYYYYY`).
- Service control on phone: `systemctl --user -M mogumo@ restart pipewire wireplumber`, `systemctl restart b2q-imsd ModemManager`.
