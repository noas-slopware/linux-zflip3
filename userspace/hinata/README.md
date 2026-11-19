# Hinata

Every cell broadcast alert the phone has received, newest first: 위급재난문자, 긴급재난문자,
안전안내문자, 실종경보문자 and whatever other channels the network sends. Tap one for its full
text, time, channel and message code.

The alerts come from [cellbroadcastd](https://gitlab.freedesktop.org/devrtz/cellbroadcastd),
which keeps them in `~/.local/share/cellbroadcastd/database.gvdb` and hands them out over
D-Bus (`libcellbroadcast`). It has no signal for a new alert; it rewrites that file, so Hinata
watches its directory (inotify) and reads the list again when it changes, and again whenever it
comes to the foreground. Nothing runs while nothing changes.

Kirigami, Qt 6. Named after Hinata Hoshino (Wataten!), who never says anything quietly.

`HINATA_SCREENSHOT=<png>` (with `HINATA_SCREENSHOT_DELAY_MS`) grabs the window once and quits,
for tests without a display (`QT_QPA_PLATFORM=offscreen`).
