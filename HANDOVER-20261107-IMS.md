# Handover: b2q IMS userspace app — 2026-11-07 late night (Pi session)

## Where we are
Branch `senpai`, HEAD `6cc8f9c` (ahead 52 of origin). Plan: `~/.commandcode/plans/b2q-userspace-ims.md`
(Phase 1.5: patch MM so plasma-dialer/spacebar work unmodified via MM Voice/Messaging delegating to b2q-imsd over D-Bus).
This session ran under the Pi harness (no subagents); prefer OpenCode/CommandCode next (`commandcode -c`).
Old OpenCode session with full context: `7ea7c8e7-d6db-431c-9e72-44c17e38e6e0`
(`~/.commandcode/projects/home-yuifunami-linux-zflip3/`, ended ~22:23).

## Committed this session
- `ae87730` imsd scaffold: `userspace/imsd/src/imsd.c` (PJSUA + sd-bus, GetState only, TODOs for P-CSCF/AKA/SMS/INVITE).
- `6cc8f9c` evidence: Phase 0 verdict (see below).

## Live state (phone, 192.168.0.105, Love-Me-for-Who-I-Am)
- Rebooted ~21:37 tonight (uptime 52m at 22:29). Modem registered LG U+ (45006), internet over qmapmux0.0 via MM bearer1 works.
- rmtfs file-backed writable override still ACTIVE (`/etc/systemd/system/rmtfs.service.d/filewritable.conf` → `rmtfs -o /root/nv-live -s`, phone-local, NOT committed). Partitions untouched.
- MM debug override still ACTIVE (`/etc/systemd/system/ModemManager.service.d/debug.conf`).
- ims_bearer.py holder ALIVE (PID 2403, since 21:47, WDS handle 2401869664, profile 4 apn=ims IPv6, mux 3 EMBEDDED/1). Second holder run's log at /tmp/ims_bearer2.log.
- **qmapmux0.3 EXISTS now** (created 22:3x this session: mux 3, MTU 1400, addr 2001:4430:1055:864b:ecee:e210:6fc9:6cff/64, default via 2001:4430:1055:864b:edb1:6ec5:aca3:bea9). Left up + holder left running. Harmless.
- **PJSIP build RUNNING**: `su build -c "makepkg -s"` in `~build/pjproject`, log `/home/build/pjproject/build-2230.log` (at pjsua-lib stage 22:4x). NOT installed yet (`pacman -Q pjproject` → not found). When done: install package, then b2q-imsd can compile against it on-phone.

## Key finding this session: Phase 0 CLOSED, modem gate confirmed MM-identical
- MM working setup captured read-only from 22:16 debug logs (no disconnect): mux-rmnet / raw-ip / qmapv5 UL+DL, dynamic mux 1, RMNET flags ingress/egress-map-cksumv5 (MM's claim; `ip -d` shows only INGRESS_DEAGGREGATION even on working qmapmux0.0 — our link reports identical flags), split v4/v6 WDS clients, Bind Mux → Start Network → Get Current Settings, MTU 1400.
- Fresh-client WDS GetCurrentSettings → `OutOfCall (15)`: settings only come from the client that started the network. Reused holder's logged values (same boot).
- L3 test on qmapmux0.3: gateway ping 6/6 lost, UDP DNS query 5s timeout, **TX 16 pkts / RX 0**. `ip link set ... type rmnet` flag tweak refused (needs mux_id restated) — irrelevant, flags already identical.
- Per plan: **SIP work pauses for L3.** The gate needs Noa's call (same options as before: PDC/CT MBN dead ends already exhausted, SIPC driver, or shelve IMS).
- NEW MM fragility: `mm_iface_modem_count_bearers` assertion `(max >= ctx.count)` crashed MM twice 22:15–22:16 (PIDs 1672→2292→2745→2938); a bearer2 appeared 21:46. Do NOT attempt MM-managed second bearers; manual WDS path only. MM restarts + reprobes in ~30s but bearer1 internet drops each time.

## Carrier constraint: LG U+ has no CS domain, and never had one

- LG U+ never ran WCDMA. Its "3G" was CDMA2000 EV-DO Rev.A/B (data only) with voice on CDMA 1x, and the government never licensed it for WCDMA the way SKT and KT were.
- With no WCDMA CS core there was nothing for LTE to fall back to, so U+ had to move voice onto IMS: VoLTE from 2012-08-08, launched as the world's first (SKT switched on the same day and the title was disputed).
- Both CDMA 1x and EV-DO are gone (2G shutdown finished 2021-06-30), so no CS domain survives anywhere: no CSFB, no 1xCSFB, no SGs association, no MSC behind it.
- VoLTE-only and SMS-over-IMS-only are therefore the shape of this network, not a U+ policy choice. `Voice support: 'no'` and `cs-domain-not-available` are the correct answers, not a misconfiguration.
- Mobile-originated and mobile-terminated SMS both have to be SIP MESSAGE (`application/vnd.3gpp.sms`, `+g.3gpp.smsip`); voice has to be SIP INVITE with the VoLTE profile (AMR-WB, P-Access-Network-Info).
- No MBN, PDC, EFS or modem setting can put a CS path back, so CSFB, SGs and 1xCSFB are dead ends the same way the modem-side IMS gate is. Do not spend time on them.
- No VoWiFi and no VoNR/5G SA either (this line has no 5G anyway): LTE IMS is the only path. IMS must work, shelving it bricks calls and SMS.

## Immediate next steps
1. Check pjproject build: `tail ~build/pjproject/build-2230.log`, `ls ~build/pjproject/*.pkg.tar.zst`. Install when built (`pacman -U` as root; deps should already be there).
2. Phase 1 daemon work is scaffolding-only until L3 moves: P-CSCF discovery, AKA auth via UIM ISIM channel, SIP MESSAGE/INVITE, sd-bus ↔ ioqueue integration. Compiles on-phone against installed pjproject.
3. Open L3 questions (need Noa): any new idea for the modem gate, or shelve IMS and do call-audio + plasma-dialer + rootfs.
4. Still uncommitted / phone-only (unchanged): `.commandcode/`, this handover file, 81voltd drop-ins, qcom-imsd `_ims_config` fix, libqmi fork PDC fix (pkgrel 2), rmtfs override, /root/nv-live, /tmp/ims_*.py + /tmp/ims_cur.py (my OutOfCall probe, reusable).

## Rules recap
- Never `systemctl restart rmtfs` while modem up (reboot phone instead). fsg is HW write-protected on sdf.
- No sleep/poll loops. Cheap/fast model for agents, no device access for subagents.
- Never flash without `B2Q_UNLOCKED=1` and stock 4-file firmware saved first (AGENTS.md).
- Device touches need explicit ask per message; this resume prompt authorizes IMS Phase 0/1 read-only + build work, NOT flashing/bearer disconnects/PDC.
- Commit messages end with `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>`. No `Co-Authored-By`.
