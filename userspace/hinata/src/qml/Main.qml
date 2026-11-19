// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import codes.noa.hinata

Kirigami.ApplicationWindow {
    id: root
    title: "Hinata"
    width: Kirigami.Units.gridUnit * 22
    height: Kirigami.Units.gridUnit * 40

    function severityColor(severity) {
        switch (severity) {
        case "presidential":
        case "extreme":
            return Kirigami.Theme.negativeTextColor
        case "severe":
        case "public-safety":
        case "amber":
            return Kirigami.Theme.neutralTextColor
        default:
            return Kirigami.Theme.disabledTextColor
        }
    }

    AlertModel {
        id: alerts
    }

    // a new alert may have come while the app was in the background
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state === Qt.ApplicationActive)
                alerts.reload()
        }
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: "Emergency Alerts"

        Kirigami.CardsListView {
            id: list
            model: alerts

            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                visible: list.count === 0 && !alerts.loading
                icon.name: alerts.error ? "network-mobile-off" : "dialog-information"
                text: alerts.error ? "Can't read the alerts" : "No alerts yet"
                explanation: alerts.error ? alerts.error
                                          : "Cell broadcast alerts this phone receives show up here."
            }

            delegate: Kirigami.AbstractCard {
                id: card
                required property string title
                required property string body
                required property string severity
                required property var time
                required property int channel
                required property int messageCode

                showClickFeedback: true
                onClicked: root.pageStack.push(Qt.resolvedUrl("AlertPage.qml"), {
                    alertTitle: card.title, alertText: card.body, severity: card.severity,
                    time: card.time, channel: card.channel, messageCode: card.messageCode,
                    accent: root.severityColor(card.severity)
                })

                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Rectangle {
                        Layout.fillHeight: true
                        Layout.preferredWidth: Kirigami.Units.smallSpacing
                        radius: width / 2
                        color: root.severityColor(card.severity)
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            Kirigami.Heading {
                                Layout.fillWidth: true
                                level: 4
                                text: card.title
                                color: root.severityColor(card.severity)
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                text: Qt.formatDateTime(card.time, "MM/dd hh:mm")
                                color: Kirigami.Theme.disabledTextColor
                            }
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: card.body
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
