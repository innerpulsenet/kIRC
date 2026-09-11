// SPDX-License-Identifier: GPL-2.0-or-later
//
// ConnectPage — first-run / reconnect form.
//
// Pure UI: it never touches IrcBridge itself. It emits connectRequested() and
// main.qml calls the bridge. It *does* listen to `error_occurred` so a failed
// attempt shows an inline hint right where the user is looking.
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
    property alias tls: tlsSwitch.checked
    property alias port: portField.text           // kept as text: unvalidated user input
    property alias saslEnabled: saslSwitch.checked
    property alias saslUser: saslUserField.text
    property alias saslPass: saslPassField.text

    // Last error pushed by the bridge, shown as an inline hint until the user
    // tries again.
    property string lastError: ""

    readonly property int parsedPort: {
        var p = parseInt(portField.text, 10)
        return isNaN(p) ? 0 : p
    }
    readonly property bool connecting: page.bridge !== null && page.bridge.connection_state === 1
    readonly property bool formValid: hostField.text.length > 0
                                      && nickField.text.length > 0
                                      && parsedPort > 0 && parsedPort <= 65535
                                      && (!saslSwitch.checked || saslUserField.text.length > 0)

    // Shared geometry, so every field lines up on one grid.
    readonly property int fieldHeight: Math.round(Kirigami.Units.gridUnit * 2.3)
    readonly property int fieldIconInset: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2
    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
    readonly property color fieldColor: Kirigami.Theme.alternateBackgroundColor

    signal connectRequested(string host, int port, bool tls, string nickname, string saslUser, string saslPass)

    Connections {
        target: page.bridge

        function onError_occurred(message) {
            page.lastError = message
        }
    }

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
            implicitHeight: form.implicitHeight + Kirigami.Units.largeSpacing * 2
            height: form.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: form
                // Capped for readability, but never wider than the viewport,
                // so the centring below can never push the form off-screen.
                width: Math.min(viewport.width, Kirigami.Units.gridUnit * 28)
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Kirigami.Units.smallSpacing

                Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }

                // ---------------- hero ---------------- //
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 3.4)
                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 3.4)
                    radius: Math.round(width * 0.3)
                    color: Kirigami.Theme.highlightColor

                    Controls.Label {
                        anchors.centerIn: parent
                        text: "#"
                        color: Kirigami.Theme.highlightedTextColor
                        font.bold: true
                        font.pointSize: Math.round(Kirigami.Theme.defaultFont.pointSize * 1.9)
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Connect to your IRC network")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 3
                    wrapMode: Text.WordWrap
                }

                Controls.Label {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Kirigami.Units.largeSpacing
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Sign in to a server and start chatting — TLS, SASL and IRCv3 included.")
                    color: Kirigami.Theme.disabledTextColor
                    wrapMode: Text.WordWrap
                }

                // ---------------- form card ---------------- //
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: cardColumn.implicitHeight + Kirigami.Units.largeSpacing * 2
                    radius: Kirigami.Units.cornerRadius + 6
                    color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.04)
                    border.width: 1
                    border.color: page.hairline

                    ColumnLayout {
                        id: cardColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing

                        Controls.Label {
                            Layout.fillWidth: true
                            text: qsTr("Server address")
                            color: Kirigami.Theme.textColor
                            opacity: 0.75
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        }

                        // ---- host ----
                        Rectangle {
                            id: hostWrapper
                            Layout.fillWidth: true
                            implicitHeight: page.fieldHeight
                            radius: Kirigami.Units.cornerRadius + 4
                            color: page.fieldColor
                            border.width: 1
                            border.color: hostField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline

                            Behavior on border.color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }

                            Kirigami.Icon {
                                anchors.left: parent.left
                                anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                                anchors.verticalCenter: parent.verticalCenter
                                source: "network-server"
                                color: hostField.activeFocus ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                            }

                            Controls.TextField {
                                id: hostField
                                anchors.fill: parent
                                text: "irc.libera.chat"
                                placeholderText: qsTr("irc.example.org")
                                background: null
                                leftPadding: page.fieldIconInset
                                rightPadding: Kirigami.Units.smallSpacing * 2
                                onAccepted: page.tryConnect()
                                onTextEdited: page.lastError = ""
                            }
                        }

                        // ---- port + TLS ----
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            text: qsTr("Port")
                            color: Kirigami.Theme.textColor
                            opacity: 0.75
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing / 2
                            spacing: Kirigami.Units.smallSpacing

                            Rectangle {
                                id: portWrapper
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 5.5)
                                implicitHeight: page.fieldHeight
                                radius: Kirigami.Units.cornerRadius + 4
                                color: page.fieldColor
                                border.width: 1
                                border.color: portField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline

                                Behavior on border.color {
                                    ColorAnimation { duration: ThemeEngine.motionDuration }
                                }

                                Kirigami.Icon {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: "security-high"
                                    color: portField.activeFocus ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                }

                                Controls.TextField {
                                    id: portField
                                    anchors.fill: parent
                                    text: "6697"
                                    inputMethodHints: Qt.ImhDigitsOnly
                                    validator: IntValidator { bottom: 1; top: 65535 }
                                    background: null
                                    leftPadding: page.fieldIconInset
                                    rightPadding: Kirigami.Units.smallSpacing * 2
                                    onAccepted: page.tryConnect()
                                    onTextEdited: page.lastError = ""
                                }
                            }

                            Item { Layout.fillWidth: true }

                            Controls.Label {
                                text: qsTr("TLS")
                                color: tlsSwitch.checked ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Controls.Switch {
                                id: tlsSwitch
                                checked: true
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.8)
                                Layout.alignment: Qt.AlignVCenter
                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: qsTr("Encrypt the connection with TLS")
                            }
                        }

                        // ---- nickname ----
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            text: qsTr("Nickname")
                            color: Kirigami.Theme.textColor
                            opacity: 0.75
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        }

                        Rectangle {
                            id: nickWrapper
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing / 2
                            implicitHeight: page.fieldHeight
                            radius: Kirigami.Units.cornerRadius + 4
                            color: page.fieldColor
                            border.width: 1
                            border.color: nickField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline

                            Behavior on border.color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }

                            Kirigami.Icon {
                                anchors.left: parent.left
                                anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                                anchors.verticalCenter: parent.verticalCenter
                                source: "im-user"
                                color: nickField.activeFocus ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                            }

                            Controls.TextField {
                                id: nickField
                                anchors.fill: parent
                                text: "kircuser"
                                placeholderText: qsTr("yournick")
                                background: null
                                leftPadding: page.fieldIconInset
                                rightPadding: Kirigami.Units.smallSpacing * 2
                                onAccepted: page.tryConnect()
                                onTextEdited: page.lastError = ""
                            }
                        }

                        // ---- SASL ----
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                text: qsTr("Authenticate with SASL")
                                color: saslSwitch.checked ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                            }

                            Controls.Switch {
                                id: saslSwitch
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.8)
                                Layout.alignment: Qt.AlignVCenter
                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: qsTr("Send SASL credentials when connecting")
                            }
                        }

                        // Expands smoothly instead of popping in.
                        Item {
                            Layout.fillWidth: true
                            clip: true
                            implicitHeight: saslSwitch.checked ? saslColumn.implicitHeight : 0
                            opacity: saslSwitch.checked ? 1 : 0
                            Behavior on implicitHeight {
                                NumberAnimation {
                                    duration: ThemeEngine.motionDuration * 2
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on opacity {
                                NumberAnimation { duration: ThemeEngine.motionDuration * 2 }
                            }

                            ColumnLayout {
                                id: saslColumn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                spacing: Kirigami.Units.smallSpacing

                                Rectangle {
                                    id: saslUserWrapper
                                    Layout.fillWidth: true
                                    implicitHeight: page.fieldHeight
                                    radius: Kirigami.Units.cornerRadius + 4
                                    color: page.fieldColor
                                    border.width: 1
                                    border.color: saslUserField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline

                                    Behavior on border.color {
                                        ColorAnimation { duration: ThemeEngine.motionDuration }
                                    }

                                    Kirigami.Icon {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: "user-identity"
                                        color: saslUserField.activeFocus ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                        implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                    }

                                    Controls.TextField {
                                        id: saslUserField
                                        anchors.fill: parent
                                        placeholderText: qsTr("SASL account name")
                                        background: null
                                        leftPadding: page.fieldIconInset
                                        rightPadding: Kirigami.Units.smallSpacing * 2
                                        onAccepted: page.tryConnect()
                                        onTextEdited: page.lastError = ""
                                    }
                                }

                                Rectangle {
                                    id: saslPassWrapper
                                    Layout.fillWidth: true
                                    implicitHeight: page.fieldHeight
                                    radius: Kirigami.Units.cornerRadius + 4
                                    color: page.fieldColor
                                    border.width: 1
                                    border.color: saslPassField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline

                                    Behavior on border.color {
                                        ColorAnimation { duration: ThemeEngine.motionDuration }
                                    }

                                    Kirigami.Icon {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: "dialog-password"
                                        color: saslPassField.activeFocus ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                        implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                    }

                                    Controls.TextField {
                                        id: saslPassField
                                        anchors.fill: parent
                                        // Never written to disk: kirc.conf is plaintext.
                                        placeholderText: qsTr("SASL password (not saved)")
                                        echoMode: TextInput.Password
                                        background: null
                                        leftPadding: page.fieldIconInset
                                        rightPadding: Kirigami.Units.smallSpacing * 2
                                        onAccepted: page.tryConnect()
                                        onTextEdited: page.lastError = ""
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------------- error hint ---------------- //
                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: page.lastError.length > 0
                    type: Kirigami.MessageType.Error
                    text: page.lastError
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

                // ---------------- primary action ---------------- //
                Controls.Button {
                    id: connectButton
                    text: page.connecting ? qsTr("Cancel") : qsTr("Connect")
                    enabled: page.connecting || page.formValid
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 2.4)
                    onClicked: {
                        if (page.connecting) {
                            if (page.bridge !== null) {
                                page.bridge.disconnect_server()
                            }
                            return
                        }
                        page.tryConnect()
                    }

                    background: Rectangle {
                        radius: Kirigami.Units.cornerRadius + 4
                        color: !connectButton.enabled
                            ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.14)
                            : (connectButton.pressed
                               ? Qt.darker(Kirigami.Theme.highlightColor, 1.2)
                               : Kirigami.Theme.highlightColor)
                        Behavior on color {
                            ColorAnimation { duration: ThemeEngine.motionDuration }
                        }
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Item { Layout.fillWidth: true }

                        Controls.BusyIndicator {
                            visible: page.connecting
                            running: page.connecting
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Kirigami.Icon {
                            visible: !page.connecting
                            source: "network-connect"
                            color: connectButton.enabled ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Controls.Label {
                            text: connectButton.text
                            color: connectButton.enabled ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.disabledTextColor
                            font.bold: true
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Item { Layout.fillWidth: true }
                    }
                }

                Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }
            }
        }
    }

    function tryConnect()
    {
        if (!page.formValid || page.connecting) {
            return
        }
        page.lastError = ""
        page.connectRequested(hostField.text,
                              page.parsedPort,
                              tlsSwitch.checked,
                              nickField.text,
                              saslSwitch.checked ? saslUserField.text : "",
                              saslSwitch.checked ? saslPassField.text : "")
    }
}
