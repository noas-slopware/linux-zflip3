# Cellular (out of scope, but not closed off)

The phone is a toy and does not need telephony. This page exists so that decisions made now
do not make a later experiment impossible.

## The network constraint

The device is an `LUC` variant (LG U+). **LG U+ never ran a 3G network** — it went from 2G
straight to LTE. There is no circuit-switched fallback, so voice on that SIM is VoLTE or
nothing. SKT and KT are also winding 3G down (new 3G sign-ups stopped in 2026), so this is
the shape of the whole country, not a quirk of one carrier.

Consequence: data is the achievable half; voice needs an IMS stack.

## The SIM constraint

The primary line lives in an eSIM on the Fold8, and Korean eSIMs are not self-transferable
(store visit, device-change fee). So the Flip3 will only ever get the iPhone 13 mini's
physical nano-SIM, i.e. the secondary line. That is a good arrangement: losing the secondary
line for an afternoon costs nothing, and the primary never moves.

Korean `SM-F711N` units shipped with eSIM disabled, so there is no way to give the Flip3 its
own line without a physical SIM.

## What a modem port would involve

1. `mpss` remoteproc plus the `mba`/modem firmware from the stock `modem` partition.
2. IPA, QRTR, `rmnet`, then ModemManager for data.
3. VoLTE: a PDC profile plus an IMS client. The open side of this moved a lot in 2026 —
   `81voltd` (QMI IMS data service), Nura's `modem/openimsd`, Catcrafts' `imsd`, and
   `hyphae` — so it is no longer hopeless, just out of scope.

## Rules for now

- Back up `efs` and `persist` in M0 even though the modem is off. Without them a later SIM
  test has no IMEI and no calibration.
- Never write to `modem`, `mdm`, `modemst1` or `modemst2`.
- Add `mpss` and `ipa` nodes to the board DTS early: cheap now, saves a DTS rewrite later.
- If cellular ever becomes the goal rather than a curiosity, the OnePlus 9/9 Pro is the same
  SoC with a much more mature port and is the better testbed. The Flip3 is the harder,
  more interesting chassis.
