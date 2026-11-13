// SPDX-License-Identifier: MIT
// One-shot helper for kita: wake the main panel.
import QtQuick
import QtQuick.Window
import org.kde.plasma.private.mobileshell.dpmsplugin as DPMS

Window {
    visible: false
    width: 1
    height: 1

    DPMS.DPMSUtil {
        id: dpms
        Component.onCompleted: dpms.turnDpmsOn()
    }

    Timer {
        interval: 300
        running: true
        onTriggered: Qt.quit()
    }
}
