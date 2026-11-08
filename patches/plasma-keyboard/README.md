# Plasma Keyboard patches

Upstream project: Plasma Keyboard, https://invent.kde.org/plasma/plasma-keyboard

Apply to: **6.8.2** (the version `extra/plasma-keyboard` has on the ports repo, and the
one installed on the phone). Upstream license: (GPL-2.0-only OR GPL-3.0-only) AND (LGPL-2.1-only OR LGPL-3.0-only).

Korean syllable composition in the preedit (via libhangul) and content-type changes passed on to the Qt Virtual Keyboard.

Why this exists: Qt Virtual Keyboard's `HangulInputMethod` composes by rewriting the
character before the cursor, which plasma-keyboard can only send as
delete-rounding-text + commit against surrounding text that lags a compositor round
trip. On the phone that gives separated jamo (ㅎㅓ instead of 허) and, in Firefox,
doubled input. Both applications and the KCM see the fix, because the input method
lives in the installed `org.kde.plasma.keyboard.lib` module.

Patches (in order):

- `0001-Compose-Korean-syllables-in-the-preedit.patch`
- `0002-Pass-content-type-changes-on-to-Qt-Virtual-Keyboard.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

`PKGBUILD` is Arch's `extra/plasma-keyboard` 6.8.2-1 recipe with `arch=(aarch64)`, a
`libhangul` dependency and the two patches applied in `prepare()`. It builds on the
phone as the `build` user (see the top of the PKGBUILD) and installs over the ports
package with `pacman -U`. The same patches and recipe are in `linux-hiby-rs6`
(pmOS: Alpine APKBUILD on 6.8.1); keep the two in sync.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch. The PKGBUILD is MIT.
