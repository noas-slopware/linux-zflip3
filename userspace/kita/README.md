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

`kita` runs on the phone, so build it there (the phone has
`aarch64-linux-gnu-gcc` and the libraries):

```sh
scp kita.c drm-lease-v1-client-protocol.h drm-lease-v1-protocol.c \
	root@<phone>:/tmp/kita/
ssh root@<phone> 'cd /tmp/kita && \
	gcc -O2 -Wall kita.c drm-lease-v1-protocol.c -o kita \
	$(pkg-config --cflags --libs gio-2.0 wayland-client libdrm cairo pangocairo) -lm && \
	install -m755 kita /usr/local/bin/kita'
install -m644 ../rootfs/etc/xdg/autostart/kita.desktop /etc/xdg/autostart/
install -m644 ../rootfs/usr/lib/udev/rules.d/82-kita-backlight.rules /usr/lib/udev/rules.d/
install -m644 ../rootfs/usr/lib/udev/rules.d/82-kita-touch.rules /usr/lib/udev/rules.d/
udevadm control --reload-rules
```

`./build.sh` on a development machine only builds x86 binaries for syntax
checks; those fail on the phone with `Exec format error`. The udev rules give
group `video` write access to `/sys/class/backlight/ae96000.dsi.0/brightness`
and keep libinput off the touchscreen. The daemon runs as the session user, not
root. The autostart file starts it with the Plasma session.

The cover sleeps by default: backlight 0 and connector DPMS Off after the
modeset. It wakes for 8 seconds on a notification, an incoming call, an SMS
(`PduReceived`), the power key (the first input device advertising
`KEY_POWER`, `pmic_pwrkey` on this phone) or a swipe on the cover touchscreen
(a touch that moves 40 units or more). A tap never wakes it. A tap while awake
dismisses the notification card it lands on and restarts the 8 seconds; it
never turns the main panel on. A call holds the display on until imsd reports
it idle or terminated (imsd's states 0, 6 or 7). Opening the lid sleeps it
again. Backlight is 160/255 while awake. It reads `LidClosed` from logind,
calls from IMSroha (`codes.noa.IMSroha`) on the system bus, and notifications from Plasma's
`org.kde.NotificationWatcher.Notify` calls through a GDBus monitor connection
on the session bus (`BecomeMonitor`), parsed from the message body.

While folded the main panel is DPMS Off, not just backlight 0: `apply_lid`
runs `qml6 /usr/local/share/kita/dpms-main-off.qml` on close and `...-on.qml`
on open, using the Plasma Mobile `DPMSUtil`. Only one helper runs at a time; a
fold or unfold during a run is applied when it exits. A folded power-key press runs the
off helper before waking the cover. PowerDevil's profiles use `LidAction=0`
and `PowerButtonAction=32` (LockScreen); the mobile default
`ToggleScreenOnOff` would wake the inside.

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
