// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    property string alertTitle
    property string alertText
    property string severity
    property var time
    property int channel
    property int messageCode
    property color accent

    title: alertTitle

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            Layout.fillWidth: true
            text: page.alertTitle
            color: page.accent
            wrapMode: Text.Wrap
        }
        QQC2.Label {
            Layout.fillWidth: true
            text: Qt.formatDateTime(page.time, Qt.locale().dateTimeFormat(Locale.LongFormat))
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.Wrap
        }
        QQC2.TextArea {
            Layout.fillWidth: true
            text: page.alertText
            readOnly: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            background: null
            leftPadding: 0
            rightPadding: 0
        }
        Kirigami.Separator {
            Layout.fillWidth: true
        }
        Kirigami.FormLayout {
            Layout.fillWidth: true
            QQC2.Label {
                Kirigami.FormData.label: "Channel:"
                text: page.channel
            }
            QQC2.Label {
                Kirigami.FormData.label: "Message code:"
                text: page.messageCode
            }
        }
    }
}
