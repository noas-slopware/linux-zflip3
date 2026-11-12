# PowerDevil patches

Upstream project: PowerDevil, https://invent.kde.org/plasma/powerdevil

Apply to: **6.8.2** (the version `plasma/powerdevil` has on the ports repo and the one
installed on the phone). Upstream license: LGPL-2.0-or-later.

Why this exists: PowerDevil handles the lid switch itself and marks the resulting action
as explicit, so `PolicyAgent::requirePolicyCheck()` is bypassed. An `InterruptSession`
inhibitor, which is what the Plasma Mobile Caffeine quick setting and
`org.freedesktop.PowerManagement.Inhibit` register, therefore does not stop the configured
Sleep or Hibernate action. Upstream tracks this as KDE bug 485623.

The patch checks the policy agent before suspending. When the session is inhibited, it
turns the display off instead and leaves the system running. Without an inhibitor the
configured lid action runs unchanged.

## 0002: suspend again after a wakeup nobody caused

After an idle suspend, a wakeup no user caused (network or modem traffic) left
the phone awake until somebody touched it, once for 8 hours. KWin's
`ext_idle_notification_v1` detectors are one-shot: the suspend timeout fires
once, and only real input arms it again. PowerDevil's resume handler calls
`KIdleTime::simulateUserActivity()`, which is a no-op on Wayland.

The patch arms a 10 s re-suspend on resume. User input (KIdleTime's resume
event, caught from the moment the suspend begins), opening the lid or a
PowerDevil scheduled wakeup (an alarm) cancel it. On expiry it runs the same
policy check as the idle timeout: while `InterruptSession` is inhibited it
waits and tries again 2 s after the inhibition goes; an inhibition requested
but not enforced yet (PowerDevil waits 5 s) is checked again 6 s later.
Otherwise it runs the profile's auto-suspend action, and nothing at all when
that action is not Sleep or Hibernate.

Debug lines, under the `org.kde.powerdevil` logging category:
`resume: armed re-suspend in 10 s`, `re-suspend: user input, cancelled`
(or `lid opened`, `scheduled wakeup`), `re-suspend: inhibited, waiting`,
`re-suspend: inhibition released, trying again in 2 s`,
`re-suspend: suspending`. Enable them with
`QT_LOGGING_RULES="org.kde.powerdevil.debug=true"` in the environment of
`plasma-powerdevil.service` (for example a user drop-in with
`Environment=QT_LOGGING_RULES=org.kde.powerdevil.debug=true`), then
`journalctl --user -u plasma-powerdevil.service`.

## Correct profile keys

PowerDevil 6 reads the lid action from the `SuspendAndShutdown` subgroup of each profile:

```ini
[AC][SuspendAndShutdown]
LidAction=1

[Battery][SuspendAndShutdown]
LidAction=1

[LowBattery][SuspendAndShutdown]
LidAction=1
```

`LidAction` values: `0` do nothing, `1` sleep, `2` hibernate, `8` shutdown, `16` logout
prompt, `32` lock screen, `64` turn off screen, `128` toggle screen. A bare `[AC]` key is
ignored, and the driver falls back to the profile default, which is Sleep on a machine
that can suspend.

## Build

`PKGBUILD` is Arch's `extra/powerdevil` 6.8.2-1 recipe with `arch=(aarch64)` and the
patches applied in `prepare()`. Build on the phone as the `build` user:

```sh
su build -c 'cd /home/build/powerdevil && makepkg -s --noconfirm'
```

Install the resulting package as root with `pacman -U`. `pkgrel` is above the ports
repo's, so the patched build wins. Restart the user service only:
`systemctl --user restart plasma-powerdevil.service`. Never restart `systemd-logind`.

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release, in order; apply
with `patch -p1` or `git am`. They are licensed like the project they patch. The PKGBUILD is MIT.
