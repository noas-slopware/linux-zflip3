# Handover 2026-11-08: VoLTE calls and MMS

Handoff for O5.5: finish VoLTE calls and MMS. Audio is out of scope here.
Repo `/home/yuifunami/linux-zflip3`, branch `senpai`. Phone `root@192.168.0.105`,
user `mogumo`, uid 1000, test SIM LG U+ 010XXXXXXXX.

Do these in order:

1. Fix the `b2q-ims-bearer` boot retry. Until it is fixed, every reboot leaves
   `qmapmux0.3` missing, `b2q-imsd` crash-looping, and both calls and MMS dead.
   This is the reason Noa's 22:24 MMS never arrived.
2. Test an incoming call from the KT phone to 010XXXXXXXX and accept it. The
   answer-call read and the empty call-list termination are fixed; this is the
   remaining live test.
3. Test MMS receive after a clean boot (no manual restarts) and MMS send from
   the Spacebar GUI (MMSC is set).
4. Then the suspend and power-off cases at the bottom.

## What is installed on the phone now

- `b2q-imsd 0.1.0-2`, built from `userspace/imsd` in this tree. Build copy:
  `/home/build/imsd.new` on the phone.
- `modemmanager 1.24.2-3`, rebuilt with `patches/modemmanager/0001-broadband-modem-qmi-add-b2q-imsd-backend-for-voice-a.patch`.
  Build tree: `/home/build/modemmanager` on the phone.
- Spacebar MMSC written to `/home/mogumo/.config/kde.org/spacebar.conf`:

  ```
  [Multimedia messages]
  mmsc=http://omammsc.uplus.co.kr:9084
  mmsProxy=
  mmsPort=8080
  ```

  `spacebar-daemon` and the app were restarted after writing it. LG U+ APN
  reference: `internet.lguplus.co.kr`, MMSC `http://omammsc.uplus.co.kr:9084`,
  no MMS proxy. The MMSC answers `405` to a GET on port 9084, so it is reachable.

## MMS: receive path works end to end

`b2q-imsd` now forwards every incoming binary RP-DATA (DCS 8-bit, WAP Push) as
`"00" + hex(TPDU)` on `org.b2q.Imsd.PduReceived` (`s`), and keeps text SMS on
the old `SmsReceived` path. ModemManager subscribes to `PduReceived`:

- `mm_sms_part_3gpp_new_from_pdu (SMS_PART_INVALID_INDEX, hexpdu, modem, &error)`
- `mm_iface_modem_messaging_take_part (...)` with `MM_SMS_STATE_RECEIVED`

Evidence: a captured LG U+ WAP Push pair (reference 0x0734, parts 1/2 and 2/2)
was injected as two SIP MESSAGEs into the daemon's own `[<ims ip>]:5060`.
MM logged the multipart assembly, Spacebar resolved `omammsc.uplus.co.kr` and
downloaded two real attachments under
`/home/mogumo/.local/share/spacebar/attachments/`:

- `1257652485/IjQhJFeCX3oRv7z.jpg` 960x1280
- `3221150440/kcrwq872AiNXR3W.jpg` 1080x2640

So notification, concatenation, and Spacebar's media download all work. The
real carrier notifications from 19:27 are in `journalctl -u b2q-imsd`.

Not yet tested: sending an MMS from the Spacebar GUI after setting the MMSC.
If it fails, read `journalctl --user` for `spacebar-daemon` (its upload path
prints `Invalid URL provided` when `mmsc().length() < 10`), and confirm the
MMSC setting loaded by restarting the daemon. The upload uses only `mmsc()`;
the proxy is only used when non-empty.

### Receive failed after the 22:24 reboot, and why

Noa sent an MMS after the reboot at ~22:24 and nothing arrived. The daemon was
not registered at all:

```
$ ip -6 -o addr show dev qmapmux0.3
Device "qmapmux0.3" does not exist.
$ systemctl is-active b2q-imsd
activating
$ journalctl -u b2q-imsd -n 20
b2q-imsd: failed to find IPv6 on qmapmux0.3: -19
b2q-imsd: imsd_sip_init failed: -19
```

The receive path itself was never reached: no interface, no REGISTER, no SIP
MESSAGE. With the interface up and the daemon registered, the same path
delivered the two attachments above.

`b2q-ims-bearer` starts before the modem is ready at boot. Its
`on_start_network_done()` only checks that a response object exists. A failed
QMI result still yields an object, the packet data handle comes back 0, and it
prints `start_network SUCCESS handle=0`, finds no IPv6 TLV, never creates
`qmapmux0.3`, and then prints `HOLDING BEARER ACTIVE...` forever. It never
retries. A manual `systemctl restart b2q-ims-bearer` a few seconds later
succeeds (handle 1058444784, IPv6 address, interface created).

Fix direction for `userspace/imsd/src/ims_bearer.c` and the unit:

- Treat a missing/failed QMI result, `handle == 0`, or no IPv6 TLV (0x25) as a
  hard failure. Do not print SUCCESS or HOLDING in that case.
- `exit(1)` so systemd retries, and add `Restart=on-failure` with a sane
  `RestartSec` (5 s) plus `StartLimitIntervalSec`/`StartLimitBurst` to
  `b2q-ims-bearer.service`. Once the modem is ready the retry succeeds.
- `b2q-imsd` already restarts on failure; keep it that way. It will bind as
  soon as the bearer creates the interface.
- Restarting ModemManager also removes `qmapmux0.3`. Either restart the bearer
  after MM (the manual sequence above), or have the bearer notice the interface
  is gone and re-run start_network. Prefer an event source over a polling
  timer; a 10 s timer is acceptable only if nothing event-driven fits.
- Immediate workaround for any MMS test: confirm
  `ip -6 -o addr show dev qmapmux0.3` has an address and
  `journalctl -u b2q-imsd` says `registered successfully` before sending.

## Calls: 114 works, on-net self-call works, KT number fails

Working:

- `mmcli -m any --voice-create-call number=114`
  - INVITE `tel:114` -> 100 / 183 / 200, call goes `active`
  - hangup: `mmcli --call=/org/freedesktop/ModemManager1/Call/N --hangup`
    -> BYE, 200 OK
- `number=010XXXXXXXX` (own number, on-net LG U+)
  - INVITE `sip:010XXXXXXXX@lte-lguplus.co.kr;user=phone`
  - 180 Ringing, 200 OK, call `active`

Failing: Noa's KT phone `010YYYYYYYY` (number is confirmed on and accepting
calls; LG U+ plays "no such number exists"). Tested URI forms:

| Dial / INVITE R-URI | Result |
|---|---|
| `sip:010YYYYYYYY@lte-lguplus.co.kr;user=phone` | 100, 183 early media, PRACK 200, then after ~7 s 404 `cause=2012203 "SERVICE CONF ERROR RESPONSE WITH MS-STATUS & CX RESULT"` |
| `sip:+8210YYYYYYYY@lte-lguplus.co.kr;user=phone` | 183, then 404 `cause=11016627 "ABNORMAL_PFX"` |
| `sip:8210YYYYYYYY@lte-lguplus.co.kr;user=phone` | 183, then 404 `cause=3022450 "DIAMETER ERROR USER UNKNOWN"` |
| `tel:010YYYYYYYY` | immediate 404, no Reason |
| `tel:+8210YYYYYYYY` | 503 `cause=9025031 "unspecified"` |

Diagnosis: the national `sip:<number>@lte-lguplus.co.kr` R-URI makes the LG U+
S-CSCF terminate on its own HSS, which is right for LG U+ subscribers (self-call
proves it) and wrong for a KT subscriber. The off-net form the stock dialer
uses is not known yet. The stock IMS APK is not in the paths checked under
`.cache/fw/super/vfs`; look in a full firmware `product`/`system_ext` image or
the Samsung IMS APK for the string used to build the R-URI, or test another
LG U+ subscriber number to confirm on-net routing is the boundary. `tel:` with
`+82` gives 503, so a `;phone-context`/tel variant may be needed if PSTN routing
is the answer.

A diagnostic escape hatch exists in `imsd_sip_place_call`: if the dial string
already starts with `sip:` or `tel:`, it is used as the R-URI and To verbatim.
That is how the table above was produced (`mmcli ... number=tel:114` and so on).
Keep it for testing or remove it once the format is settled.

## Incoming calls: code fixed, live test still pending

Two fixes are in `b2q-imsd`:

- `handle_incoming_invite()` no longer emits a second `CallStateChanged(2)`
  after `CallAdded`; that flipped an incoming call to ringing-out in MM.
- `method_answer_call()` reads the `u` call id before answering.

The 2.3 s answer drop was mostly MM's call-list polling. Previously
`modem_voice_load_call_list` returned an empty list, so MM logged
`reported 0 ongoing calls` and terminated the call. The b2q backend now tracks
the current call from `CallAdded`/`CallStateChanged` and
`mm_ims_backend_b2q_get_call_list()` returns it as `MMCallInfo`; MM now logs
`reported 1 ongoing calls ... state ringing-out/active` and does not terminate.

Ring states are direction-aware: outgoing 180/183 emit state 2 (ringing-out),
incoming 180/183 emit state 3 (ringing-in), active 4, terminated 6.

To finish this: call 010XXXXXXXX from another phone, watch
`mmcli -m any --voice-list-calls`, then
`mmcli --call=/org/freedesktop/ModemManager1/Call/N --accept`. It should stay
`active` past 2.3 s. If it drops, capture `journalctl -u ModemManager` around
the accept and `journalctl -u b2q-imsd` for the 200 OK/ACK.

## Sleeping, power-off, and messages or calls that were missed

This is untested and is the next big gap after the boot fix. What the code does
today:

- The port suspends with s2idle. Lid close suspends, lid open wakes.
- `b2q-imsd` arms its REGISTER refresh and SMS timeout with
  `sd_event_add_time(..., CLOCK_MONOTONIC, ...)`. CLOCK_MONOTONIC does not
  advance during suspend, so a refresh due while asleep does not run on resume
  until the same amount of awake time has passed again. A long suspend can let
  the 10800 s registration lapse.
- The IMS PDN (`qmapmux0.3`) is held by `b2q-ims-bearer` as a WDS call. On
  suspend the rmnet link stays in the modem, but the host does not process
  packets. A SIP INVITE or MESSAGE is only handled if the modem and QRTR wake
  the AP. Whether the modem is a wakeup source on this port is unknown.
- On power-off, the SMSC stores SMS and retries when the UE re-registers. MMS
  notifications are SMS, so they are retried too, but the MMSC media has an
  expiry. Nothing can arrive until the IMS PDN and REGISTER are back, which the
  boot bearer bug currently prevents.

What to test, in this order:

1. Power-off delivery. Turn the Flip3 off, send it one SMS and one MMS from
   the KT phone, boot it, wait for `mmcli -L` and for `b2q-imsd` to log
   `registered successfully`, then check `mmcli -m any --messaging-list-sms`
   and Spacebar. With the bearer retry fixed, the SMSC retry should deliver
   both. If the MMS notification is old, the media may have expired on the
   MMSC and that is not a local bug.
2. Suspend and incoming SMS. Close the lid, send an SMS, open the lid. Check
   whether the SIP MESSAGE was processed before or after resume and whether
   `journalctl -u b2q-imsd` shows it. If the packet is lost, the SMSC will
   retry later, so a delay is acceptable; a permanent miss is not.
3. Suspend and incoming call. Close the lid, call 010XXXXXXXX from the KT
   phone. Does it ring or go to missed-call/voicemail? On resume check
   `dmesg | tail -40`, `cat /sys/power/wakeup_count` before and after, and
   `sort -k6 -n /sys/kernel/debug/wakeup_sources | tail -20` (if debugfs is
   mounted). If the modem/QRTR is not a wakeup source, the call cannot wake
   the AP.
4. If the call cannot wake the AP, the fix is a proper modem wake IRQ in the
   kernel (`device_init_wakeup`, `enable_irq_wake` on the QRTR/IPA/modem
   interrupt), not a permanent userspace wakelock. A wakelock that keeps the
   AP awake while IMS is registered burns power doing nothing and is against
   the standing rule. O5.5 decides whether the missing wakeup is in scope here
   or belongs to a separate kernel task.
5. Timer fix: use `CLOCK_BOOTTIME` for the REGISTER refresh so an overdue
   refresh fires immediately after resume. The RTP TX timer can stay
   CLOCK_MONOTONIC. A simple re-register on resume is to subscribe to logind's
   `PrepareForSleep(false)` over D-Bus and call `imsd_sip_register()`.
6. Interface change: `b2q-imsd` reads the IMS IPv6 once in `imsd_sip_init` and
   binds the socket to it. If the bearer is restarted and the address changes,
   imsd must be restarted or must watch for the address change. There is no
   netlink watch today. At minimum the unit ordering should be
   `After=b2q-ims-bearer.service`, and the bearer should restart imsd (or the
   daemon should reconnect) when it recreates the interface.
7. After resume, check `ip -6 -o addr show dev qmapmux0.3` and
   `systemctl is-active b2q-imsd`. If the PDN was torn down, restart the
   bearer (twice if needed) and imsd, then confirm
   `registered successfully` before trusting incoming delivery.

## Device state after every reboot

These steps are needed in this order, every time:

1. `mmcli -L`. If it says `No modems were found`, `systemctl restart ModemManager`
   and wait ~30 s.
2. Restart `b2q-ims-bearer` and check `ip -6 -o addr show dev qmapmux0.3`.
   The first start after boot often succeeds without creating the interface;
   restart the service a second time.
3. `systemctl restart b2q-imsd`. Check `journalctl -u b2q-imsd` for
   `registered successfully`.
4. Restarting ModemManager removes `qmapmux0.3`. Redo steps 2 and 3.

## Build and install

imsd:

```sh
tar czf /tmp/imsd.tgz --exclude=build userspace/imsd
scp /tmp/imsd.tgz root@192.168.0.105:/tmp/
# on the phone:
rm -rf /home/build/imsd.new && mkdir -p /home/build/imsd.new
tar xzf /tmp/imsd.tgz -C /home/build/imsd.new --strip-components=1
chown -R build:build /home/build/imsd.new
su - build -s /bin/bash -c 'cd /home/build/imsd.new/packaging && B2Q_IMSD_SRC=/home/build/imsd.new makepkg -sf --noconfirm'
pacman -U --noconfirm --overwrite '*' /home/build/imsd.new/packaging/b2q-imsd-0.1.0-2-aarch64.pkg.tar.zst
systemctl restart b2q-imsd
```

ModemManager:

```sh
scp patches/modemmanager/0001-*.patch root@192.168.0.105:/home/build/modemmanager/
# on the phone, as build:
rm -rf /home/build/modemmanager/src /home/build/modemmanager/pkg
cd /home/build/modemmanager && makepkg -f --noconfirm
pacman -U --noconfirm --overwrite '*' modemmanager-1.24.2-3-aarch64.pkg.tar.zst
systemctl restart ModemManager
```

The MM patch was regenerated and applies cleanly to the 1.24.2 tag. Do not
hand-edit hunk headers; regenerate the patch with `git diff` and check it with
`git apply --check` in a clean tree.

## Changed files

- `userspace/imsd/src/sip.c`: PDU forwarding, direction-aware ring states,
  call URI rules, removed `/root/yurushite_neko.amrwb_frames`, removed the
  redundant incoming `CallStateChanged(2)`, call-list state tracking hooks.
- `userspace/imsd/src/sms.c`, `sms.h`: RP address skip is spec-correct now.
- `userspace/imsd/src/dbus.c`, `dbus.h`: `PduReceived` signal.
- `userspace/imsd/src/imsd.c`: `PduReceived` in the vtable, answer call id read.
- `patches/modemmanager/0001-...patch`: PduReceived handler, call tracking,
  `mm_ims_backend_b2q_get_call_list`, real `modem_voice_load_call_list`.

## Audio files touched in this session (CO5.5 owns audio)

Do not revert these; the speaker works with them.

- `userspace/rootfs/usr/share/alsa/ucm2/Qualcomm/sm8250/SM-F711N/HiFi.conf`
- `userspace/rootfs/usr/share/alsa/ucm2/Qualcomm/sm8250/SM-F711N/SM-F711N.conf`
- `userspace/rootfs/etc/wireplumber/wireplumber.conf.d/50-no-video-capture.conf`

The UCM master defines `pcm.b2q_tdm` inside `LibraryConfig.b2q.Config` as a
plug pinned to S16_LE/48 kHz/2ch, because ACP was opening S24_32LE and the TDM
backend carries S16_LE. The WirePlumber drop-in disables the V4L2 capture
monitor: the only V4L2 nodes are the qcom-iris codec devices, whose firmware is
missing, and their failed `create-v4l2-device` events wedged the event
dispatcher at priority 500 so every later audio node event was dropped.
