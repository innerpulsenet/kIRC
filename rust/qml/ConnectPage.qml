// SPDX-License-Identifier: GPL-2.0-or-later
//
// ConnectPage — first-run / reconnect form.
//
// Pure UI: it never touches IrcBridge itself. It emits connectRequested() and
// main.qml calls the bridge. Field values live here so main.qml can pre-fill
// them later from ~/.config/kIRC/kirc.conf once the C++ side exposes it
// (see README.md "Config persistence").

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

Kirigami.Page {
    id: page

    // Set by main.qml. Only used to reflect connection state (e.g. disable
    // the button while a connection attempt is in flight); all actions go out
    // through the connectRequested signal.
    property var bridge: null

    property alias host: hostField.text
    property alias nickname: nickField.text
    property alias tls: tlsCheck.checked
    property alias port: portField.text           // kept as text: unvalidated user input
    property alias saslEnabled: saslCheck.checked
    property alias saslUser: saslUserField.text
    property alias saslPass: saslPassField.text

    readonly property int parsedPort: {
        var p = parseInt(portField.text, 10)
        return isNaN(p) ? 0 : p
    }
    readonly property bool connecting: page.bridge !== null && page.bridge.connection_state === 1
    readonly property bool formValid: hostField.text.length > 0
                                      && nickField.text.length > 0
                                      && parsedPort > 0 && parsedPort <= 65535
                                      && (!saslCheck.checked || saslUserField.text.length > 0)

    signal connectRequested(string host, int port, bool tls, string nickname, string saslUser, string saslPass)

    title: qsTr("Connect to IRC")
    padding: 0

    Controls.ScrollView {
        id: scroll
        anchors.fill: parent

        ColumnLayout {
            id: form
            width: Math.min(scroll.availableWidth - Kirigami.Units.gridUnit * 2,
                            Kirigami.Units.gridUnit * 28)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }

            Controls.Label {
                text: qsTr("Server")
                font.bold: true
                Layout.fillWidth: true
            }

            Controls.TextField {
                id: hostField
                text: "irc.libera.chat"
                placeholderText: qsTr("irc.example.org")
                Layout.fillWidth: true
                onAccepted: page.tryConnect()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.TextField {
                    id: portField
                    text: "6697"
                    inputMethodHints: Qt.ImhDigitsOnly
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                    validator: IntValidator { bottom: 1; top: 65535 }
                    onAccepted: page.tryConnect()
                }

                Controls.CheckBox {
                    id: tlsCheck
                    text: qsTr("Use TLS")
                    checked: true
                }

                Item { Layout.fillWidth: true }
            }

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

            Controls.Label {
                text: qsTr("Nickname")
                font.bold: true
                Layout.fillWidth: true
            }

            Controls.TextField {
                id: nickField
                text: "kircuser"
                placeholderText: qsTr("yournick")
                Layout.fillWidth: true
                onAccepted: page.tryConnect()
            }

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

            Controls.CheckBox {
                id: saslCheck
                text: qsTr("Authenticate with SASL")
                Layout.fillWidth: true
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                visible: saslCheck.checked
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("SASL username")
                    Layout.fillWidth: true
                }

                Controls.TextField {
                    id: saslUserField
                    placeholderText: qsTr("account name")
                    Layout.fillWidth: true
                }

                Controls.Label {
                    text: qsTr("SASL password")
                    Layout.fillWidth: true
                }

                Controls.TextField {
                    id: saslPassField
                    placeholderText: qsTr("password (stored in kirc.conf)")
                    echoMode: TextInput.Password
                    Layout.fillWidth: true
                    onAccepted: page.tryConnect()
                }
            }

            Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }

            Controls.Button {
                id: connectButton
                text: page.connecting ? qsTr("Connecting…") : qsTr("Connect")
                icon.name: "network-connect"
                enabled: page.formValid && !page.connecting
                Layout.fillWidth: true
                onClicked: page.tryConnect()
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: portField.text.length > 0 && page.parsedPort === 0
                type: Kirigami.MessageType.Error
                text: qsTr("Port must be a number between 1 and 65535.")
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: !page.formValid && !page.connecting && page.parsedPort !== 0
                type: Kirigami.MessageType.Warning
                text: qsTr("Enter a server host and a nickname to continue.")
            }

            Item { Layout.fillHeight: true }
        }
    }

    function tryConnect()
    {
        if (!page.formValid || page.connecting) {
            return
        }
        page.connectRequested(hostField.text,
                              page.parsedPort,
                              tlsCheck.checked,
                              nickField.text,
                              saslCheck.checked ? saslUserField.text : "",
                              saslCheck.checked ? saslPassField.text : "")
    }
}
