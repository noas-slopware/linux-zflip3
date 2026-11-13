// SPDX-License-Identifier: MIT
// One-shot helper for kita: put the main panel's DPMS to sleep.
import QtQuick
import QtQuick.Window
import org.kde.plasma.private.mobileshell.dpmsplugin as DPMS

Window {
    visible: false
    width: 1
    height: 1

    DPMS.DPMSUtil {
        id: dpms
        Component.onCompleted: dpms.turnDpmsOff()
    }

    Timer {
        interval: 300
        running: true
        onTriggered: Qt.quit()
    }
}
