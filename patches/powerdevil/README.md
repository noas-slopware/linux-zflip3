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
patch applied in `prepare()`. Build on the phone as the `build` user:

```sh
su build -c 'cd /home/build/powerdevil && makepkg -s --noconfirm'
```

Install the resulting package as root with `pacman -U`. `pkgrel` is above the ports
repo's, so the patched build wins. Restart the user service only:
`systemctl --user restart plasma-powerdevil.service`. Never restart `systemd-logind`.

Authors: Noa Himesaka <himesaka@noa.codes>.

The patch is `git format-patch` output against the upstream release; apply with
`patch -p1` or `git am`. It is licensed like the project it patches. The PKGBUILD is MIT.
