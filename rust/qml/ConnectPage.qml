// SPDX-License-Identifier: GPL-2.0-or-later
//
// ConnectPage — first-run / reconnect form.
//
// Pure UI: it never touches IrcBridge itself. It emits connectRequested() and
// main.qml calls the bridge.
//
// The fields are prefilled from the persisted profile through the `kircConfig`
// context property (a KircConfig, see cpp/kircconfig.cpp).  That property only
// exists in the real application: standalone/offline harnesses instantiate
// this page without it, so the prefill is guarded on null and the page keeps
// working with its built-in defaults.
//
// LAYOUT NOTE: the form must never be positioned against its direct `parent`.
// Inside a ScrollView that parent is the flickable's *content item*, whose
// width is the content's own implicit width (a couple of hundred pixels), so
// centring a ~500px form in it put the form at a negative x and clipped every
// label and field off the left edge.  The layout below therefore sizes an
// explicit viewport item from the ScrollView itself and anchors the form
// inside that, with no absolute coordinates.

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

    // Persisted connection profile (KircConfig). Null in standalone harnesses.
    property var kircConfig: null

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

    // Kirigami.Page owns the content padding; the scroll view below fills the
    // resulting (inset) content area, so the form can never touch the window
    // border.
    padding: Kirigami.Units.largeSpacing

    // Prefill from the persisted profile once every field exists.  The SASL
    // password is never persisted (see cpp/kircconfig.h), so it stays empty.
    Component.onCompleted: {
        if (page.kircConfig === null || page.kircConfig === undefined) {
            return
        }
        var cfg = page.kircConfig
        if (cfg.host.length > 0) {
            page.host = cfg.host
        }
        if (cfg.port > 0 && cfg.port <= 65535) {
            page.port = String(cfg.port)
        }
        page.tls = cfg.tls
        if (cfg.nickname.length > 0) {
            page.nickname = cfg.nickname
        }
        if (cfg.saslUser.length > 0) {
            page.saslEnabled = true
            page.saslUser = cfg.saslUser
        }
    }

    Controls.ScrollView {
        id: scroll
        anchors.fill: parent
        // Vertical scrolling only: the form is width-constrained below, so
        // there is nothing to scroll horizontally.
        contentWidth: availableWidth

        // Sizes itself from the ScrollView (i.e. the real viewport) rather
        // than from the flickable's content item — see the layout note above.
        Item {
            id: viewport
            width: scroll.availableWidth
            implicitHeight: form.implicitHeight
            height: form.implicitHeight

            ColumnLayout {
                id: form
                // Capped for readability, but never wider than the viewport,
                // so the centring below can never push the form off-screen.
                width: Math.min(viewport.width, Kirigami.Units.gridUnit * 28)
                anchors.top: parent.top
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
                        // Never written to disk: kirc.conf is plaintext.
                        placeholderText: qsTr("password (not saved)")
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
            }
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
