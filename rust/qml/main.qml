// SPDX-License-Identifier: GPL-2.0-or-later
//
// main.qml — kIRC application window.
//
// Owns the single IrcBridge instance (cxx-qt QML element, snake_case members)
// and the page stack: ConnectPage first, then ChatPage once connected.
//
// The GUI is deliberately not responsible for reconnecting, retrying or
// persisting anything: the Rust side owns IRC state, this file only reflects
// it. Connection details are *not* persisted here — they belong in
// ~/.config/kIRC/kirc.conf, written by the C++ side (see README.md).

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirc

Kirigami.ApplicationWindow {
    id: root

    width: 1024
    height: 700
    minimumWidth: 480
    minimumHeight: 360
    title: root.headerTitle + " — kIRC"

    // The one and only bridge object. Children get it through the `bridge`
    // property (QML ids are file-scoped, so it cannot be referenced directly
    // from ConnectPage/ChatPage).
    readonly property IrcBridge bridge: ircBridge

    IrcBridge {
        id: ircBridge
    }

    // Updated by ChatPage when the user switches channel.
    property string chatChannel: "#kirc"

    readonly property string headerTitle: {
        if (root.pageStack.depth > 1) {
            return qsTr("Chat — %1").arg(root.chatChannel)
        }
        return qsTr("Connect to IRC")
    }

    readonly property string statusText: {
        switch (root.bridge.connection_state) {
        case 0: return qsTr("Disconnected")
        case 1: return qsTr("Connecting…")
        case 2: return qsTr("Connected")
        }
        return qsTr("Disconnected")
    }

    readonly property color statusColor: root.bridge.connection_state === 2
        ? Kirigami.Theme.positiveTextColor
        : (root.bridge.connection_state === 1
           ? Kirigami.Theme.neutralTextColor
           : Kirigami.Theme.negativeTextColor)

    // ---------------------------------------------------------------------- //
    // Header: connection state + nick + unread count (per the UI contract).
    // Replaces the default global toolbar, so the page title and a back button
    // are re-created here.
    // ---------------------------------------------------------------------- //
    header: Controls.ToolBar {
        id: headerBar

        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Controls.ToolButton {
                icon.name: "go-previous"
                text: qsTr("Back")
                display: Controls.AbstractButton.IconOnly
                visible: root.pageStack.depth > 1
                onClicked: root.pageStack.pop()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Back to connection settings")
            }

            Controls.Label {
                text: root.headerTitle
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Controls.Label {
                text: root.statusText
                color: root.statusColor
            }

            Controls.Label {
                visible: root.bridge.unread_count > 0
                text: qsTr("%1 unread").arg(root.bridge.unread_count)
                color: Kirigami.Theme.neutralTextColor
            }

            Controls.Label {
                visible: root.bridge.nickname.length > 0
                text: root.bridge.nickname
                color: Kirigami.Theme.disabledTextColor
            }

            Controls.ToolButton {
                icon.name: "network-disconnect"
                text: qsTr("Disconnect")
                display: Controls.AbstractButton.IconOnly
                visible: root.bridge.connection_state !== 0
                onClicked: root.bridge.disconnect_server()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Disconnect")
            }

            Controls.ToolButton {
                id: themeButton
                icon.name: "preferences-desktop-theme"
                text: qsTr("Theme")
                display: Controls.AbstractButton.IconOnly
                onClicked: themeMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Theme")

                Controls.Menu {
                    id: themeMenu
                    title: qsTr("Theme")

                    // Built-in (compiled-in) themes. Additional themes from
                    // ~/.config/kIRC/themes/ are appended by the C++ side, which
                    // is expected to extend ThemeEngine.availableThemeIds and
                    // call ThemeEngine.applyThemeJson() when one is picked.
                    Instantiator {
                        model: ThemeEngine.availableThemeIds

                        delegate: Controls.MenuItem {
                            id: themeItem
                            required property string modelData

                            text: ThemeEngine.themeDisplayName(themeItem.modelData)
                            checkable: true
                            checked: ThemeEngine.themeId === themeItem.modelData
                            onTriggered: ThemeEngine.applyBuiltinTheme(themeItem.modelData)
                        }

                        onObjectAdded: (index, object) => themeMenu.insertItem(index, object)
                        onObjectRemoved: (index, object) => themeMenu.removeItem(object)
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // Page stack
    // ---------------------------------------------------------------------- //
    pageStack.initialPage: ConnectPage {
        bridge: root.bridge

        onConnectRequested: (host, port, tls, nickname, saslUser, saslPass) => {
            root.bridge.connect_server(host, port, tls, nickname, saslUser, saslPass)
            root.openChat()
        }
    }

    // ---------------------------------------------------------------------- //
    // Bridge signals handled at window level
    // ---------------------------------------------------------------------- //
    Connections {
        target: root.bridge

        function onState_changed(state) {
            if (state === 2) {
                // Connected: make sure the chat page is up even if the
                // connection was started from somewhere else.
                root.openChat()
            } else if (state === 0 && root.pageStack.depth > 1) {
                // Dropped: fall back to the connection form so the user can
                // retry. The bridge keeps the error detail.
                root.pageStack.pop()
            }
        }

        function onNotification_fired(title, body) {
            root.showPassiveNotification(title.length > 0 ? (title + " — " + body) : body)
        }

        function onError_occurred(message) {
            root.showPassiveNotification(message, 5000)
        }

        function onInfo(text) {
            root.showPassiveNotification(text)
        }
    }

    // ---------------------------------------------------------------------- //
    // Helpers
    // ---------------------------------------------------------------------- //
    function openChat()
    {
        if (root.pageStack.depth > 1) {
            return
        }
        root.pageStack.push(Qt.resolvedUrl("ChatPage.qml"), {
            "bridge": root.bridge,
            "hostWindow": root,
            "currentChannel": root.chatChannel
        })
    }
}
