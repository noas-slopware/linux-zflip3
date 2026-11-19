# b2q cover display

The Galaxy Z Flip3 cover is a 512x260 landscape strip. The panel scans out a
260x512 image and is mounted rotated, so the daemon renders a 512x260 logical
frame and rotates it +90 degrees (`cairo_rotate(M_PI / 2)`) into the
framebuffer. The connector is marked
`non-desktop` in `panel-samsung-s6e36w3.c`; KWin and KScreen do not create a
screen for it, which is what the mobile shell, Firefox's mobile profile and the
app switcher need.

KWin only offers non-desktop connectors through `wp_drm_lease_v1`. `kita`
leases DSI-2, owns it with DRM/KMS and draws the clock, up to three
notifications and the incoming-call banner with Cairo/Pango. Page flips on the
leased CRTC deliver no completion events, so redraws use `drmModeDirtyFB`.

## Build and install

The `kita` package (`arch` branch, `kita/PKGBUILD`) builds this directory with meson:

```sh
meson setup --prefix=/usr --sysconfdir=/etc build && meson compile -C build
meson install -C build
```

It installs `/usr/bin/kita`, the two DPMS helpers in `/usr/share/kita/`, the autostart
file in `/etc/xdg/autostart/` and the udev rules in `/usr/lib/udev/rules.d/`. The
drm-lease protocol code is generated from wayland-protocols' `drm-lease-v1.xml` at build
time. `lease-modeset`, the bring-up probe, is built but not installed.

The udev rules give group `video` write access to `/sys/class/backlight/ae96000.dsi.0/brightness`
and keep libinput off the touchscreen. The daemon runs as the session user, not
root. The autostart file starts it with the Plasma session.

The cover sleeps by default: backlight 0 and connector DPMS Off after the
modeset. It wakes for 8 seconds (30 for an emergency alert) on a notification, an incoming call, an SMS
(`PduReceived`), the power key (the first input device advertising
`KEY_POWER`, `pmic_pwrkey` on this phone) or a swipe on the cover touchscreen
(a touch that moves 40 units or more). A tap never wakes it. A tap while awake
dismisses the notification card it lands on and restarts the 8 seconds; it
never turns the main panel on. A call holds the display on until imsd reports
it idle or terminated (imsd's states 0, 6 or 7). Opening the lid sleeps it
again. Backlight is 160/255 while awake. It reads `LidClosed` from logind,
calls from IMSroha (`codes.noa.IMSroha`) on the system bus, and notifications as a
registered Plasma notification watcher: it serves `org.kde.NotificationWatcher` at
`/NotificationWatcher` and calls `org.kde.NotificationManager.RegisterWatcher` whenever
`org.freedesktop.Notifications` appears; Plasma then calls its `Notify` for every
notification and `CloseNotification` when one goes. (It used to watch Plasma's calls to
other watchers with a monitor connection, which saw nothing while none was registered.)

While folded the main panel is DPMS Off, not just backlight 0: `apply_lid`
runs `qml6 /usr/share/kita/dpms-main-off.qml` on close and `...-on.qml`
on open, using the Plasma Mobile `DPMSUtil`. Only one helper runs at a time; a
fold or unfold during a run is applied when it exits. A folded power-key press runs the
off helper before waking the cover. PowerDevil's profiles use `LidAction=0`
and `PowerButtonAction=32` (LockScreen); the mobile default
`ToggleScreenOnOff` would wake the inside.

## Emergency alerts

A notification whose category is a cell broadcast one (cellbroadcastd's
`x-phosh-cellbroadcast.<level>`, or `cellbroadcast.<level>`) takes the whole cover:
red for presidential and extreme alerts (위급재난문자, 긴급재난문자), orange for severe and
public safety ones (안전안내문자), yellow for AMBER (실종경보문자), grey for tests. The newest
alert stays on the cover, over the clock and the cards, until a tap dismisses it or 10
minutes pass, and it keeps the cover lit for 30 seconds instead of 8. Its sound is
cellbroadcastd's, not kita's.

## Power key

Folded, the power key wakes the cover when it is dark and turns it off when it is lit.
Turning it off releases kita's inhibition and then asks PowerDevil whether anything else
holds the phone awake (`HasInhibit`: Caffeine, a call, playing media); if nothing does,
it suspends (`org.freedesktop.PowerManagement.Suspend`). The cards stay for the next wake.

## Tests

`kita --no-display --dump frame.png --power-key FIFO` takes no lease and touches no
backlight, DRM or main panel: it draws into memory and writes each frame to the PNG, and
reads `struct input_event`s from the FIFO. With fake logind and PowerDevil on private
buses this runs the alert screen and the power key logic on any machine.

## Keeping the phone awake

`kita` holds one `org.freedesktop.PowerManagement.Inhibit` inhibition
(session bus, `Inhibit("kita", reason)`) while the cover is lit, and while any
ModemManager call is not terminated: dialing, ringing in or out, active, held
or waiting (`MMCallState` 1 to 6). Calls come from ModemManager's
`Modem.Voice` (`CallAdded`, `CallDeleted`, `Calls`) and each call's
`StateChanged` on the system bus; IMSroha reports VoLTE calls there too, so
ringing and dialing calls count whether or not the phone is folded. The call
list is read again when ModemManager or a modem appears and dropped when
ModemManager goes away. The inhibition is released when neither reason holds,
and taken again if PowerDevil restarts.

With PowerDevil's patch 0002 (`patches/powerdevil`) a wakeup nobody caused
suspends again after 10 s. The cover stays lit for its 8 seconds and the
phone sleeps shortly after it goes dark. PowerDevil enforces an inhibition 5 s
after it is requested. The journal shows `inhibit: requesting (cover|call)`,
`inhibit: holding`, `inhibit: released` and `calls: N not terminated`.

## Heat

`kita` is event-driven. While the cover sleeps no timer runs at all.
While it is lit there are two one-shot timeouts: one at the next minute
boundary for the clock and one at the earliest notification expiry (90 s after
it arrived); expired cards are also pruned on every wake. The cover is DPMS Off
while asleep. The big display load was the main 120 Hz panel staying
enabled while folded, even at backlight 0. It is DPMS off while folded, and KWin
then idles.

## Probe

`lease-modeset.c` is the original bring-up probe: it leases DSI-2, creates a
dumb buffer and sets a solid colour. It is useful when the daemon's lease path
needs checking without the UI.
