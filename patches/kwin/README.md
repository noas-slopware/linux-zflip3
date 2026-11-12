# KWin patches

Upstream project: KWin, https://invent.kde.org/plasma/kwin

Apply to: **6.8.2** (the version `plasma/kwin` has on the ports repo and the one installed
on the phone), after Arch's c9d720793 ("Fix crashes"), as the PKGBUILD does. Upstream
license: GPL-2.0-or-later.

Why this exists: KWin takes a logind delay inhibitor, "turning screens off", while the
screens are on, and releases it once they are off. On the phone it never released it before
a suspend: logind waited its `InhibitDelayMaxSec` (5 s) every time, 125 of 125 suspends on
2026-11-12 ("Delay lock is active ... kwin_wayland ... but inhibitor timeout is reached").
For those 5 s the lock screen was up while fprintd had already suspended the reader, so
scans failed (fprintd 0002 is the other half of that).

## 0001: ignore dpms wakeups once the system is going to sleep

Upstream commit 6a7b78b40 (master, not in 6.8), context adjusted for 6.8.2. Input that arrives
after `PrepareForSleep(true)` used to turn the screens back on and keep the inhibitor.

## 0002: don't wait for non-desktop outputs to turn off

`Workspace::maybeUpdateDpmsState()` went to Off, and released the inhibitor, only once every
backend output reported DPMS off. `applyOutputChanges()` leaves non-desktop outputs alone: they
are for leasing, and the cover display (DSI-2, `non-desktop` in `panel-samsung-s6e36w3.c`) is
leased to `kita`. Its DPMS mode never changes, so Off was never reached. 0002 skips non-desktop
outputs there and when deciding that there is no output to turn off at all.

Tested with KWin's integration tests in an Arch container on the desktop: the new
`testDpmsOffWithNonDesktopOutput` fails without 0002 and passes with it, as does upstream's
`testDpmsWakeDuringSleep`. The rest of the suite fails the same tests with and without the
patches there (no GPU or X display in the container; `testInputMethod` was flaky under
`ctest -j10` and passes alone on both).
