// SPDX-License-Identifier: GPL-2.0-or-later
//
// main.qml — kIRC application window.
//
// Owns the single IrcBridge instance (cxx-qt QML element, snake_case members)
// and the page stack: ConnectPage first, then ChatPage once connected.
//
// The GUI is deliberately not responsible for reconnecting or retrying: the
// Rust side owns IRC state, this file only reflects it.
//
// Native integration (all optional, all guarded): the C++ side exposes
//   * `kircConfig` — a KircConfig persisting the last connection profile to
//     ~/.config/kIRC/kirc.conf (cpp/kircconfig.cpp), and
//   * `kircTray`   — a KircTray/KStatusNotifierItem (cpp/kirctray.cpp).
// Neither exists when this file is loaded by the standalone QML harness, so
// every use is null-guarded and the window keeps working without them.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirc

Kirigami.ApplicationWindow {
    id: root

    width: 1024
    height: 700
    // Wide/tall enough for the connection form (capped at gridUnit*28 plus
    // page padding) plus the header; a narrower minimum let the form clip.
    minimumWidth: Kirigami.Units.gridUnit * 32
    minimumHeight: Kirigami.Units.gridUnit * 24
    title: root.headerTitle + " — kIRC"

    // The one and only bridge object. Children get it through the `bridge`
    // property (QML ids are file-scoped, so it cannot be referenced directly
    // from ConnectPage/ChatPage).
    // The objectName is the handle the C++ side uses (findChild) to reach the
    // bridge after the engine has loaded it — see cpp/main.cpp.
    readonly property IrcBridge bridge: ircBridge

    IrcBridge {
        id: ircBridge
        objectName: "ircBridge"
    }

    // Updated by ChatPage when the user switches channel.
    property string chatChannel: "#kirc"

    // ---------------------------------------------------------------------- //
    // Persisted profile (KircConfig). `appConfig` is null in harnesses that do
    // not provide the context property.
    // ---------------------------------------------------------------------- //
    readonly property var appConfig: {
        try {
            return (typeof kircConfig !== "undefined" && kircConfig !== null) ? kircConfig : null
        } catch (e) {
            return null
        }
    }

    readonly property bool minimizeToTray: root.appConfig !== null
                                           ? root.appConfig.minimizeToTray : true

    // True once a StatusNotifierItem host (Plasma panel) is registered, i.e.
    // once hiding the window is actually recoverable. `kircTray` is absent in
    // harnesses, where this stays false.
    readonly property bool trayAvailable: {
        try {
            return (typeof kircTray !== "undefined" && kircTray !== null) ? kircTray.available : false
        } catch (e) {
            return false
        }
    }

    // Last connection attempt, captured so a *successful* connect can be
    // persisted (the bridge owns the real state; this is just what the user
    // typed).
    property string lastHost: ""
    property int lastPort: 0
    property bool lastTls: true
    property string lastNickname: ""
    property string lastSaslUser: ""

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
    // Close = hide to tray (when a tray is available and the setting is on).
    // The tray's "Quit kIRC" action and the menu item below bypass this by
    // calling Qt.quit()/QCoreApplication::quit(), which never triggers a
    // window close.
    // ---------------------------------------------------------------------- //
    onClosing: (close) => {
        if (root.trayAvailable && root.minimizeToTray) {
            close.accepted = false
            root.hide()
        }
    }

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

            Controls.ToolButton {
                id: appMenuButton
                icon.name: "application-menu"
                text: qsTr("Menu")
                display: Controls.AbstractButton.IconOnly
                onClicked: appMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Menu")

                Controls.Menu {
                    id: appMenu

                    Controls.MenuItem {
                        text: root.trayVisibleLabel()
                        icon.name: root.visible ? "window-minimize" : "window-restore"
                        enabled: root.trayAvailable
                        onTriggered: root.toggleToTray()
                    }

                    Controls.MenuItem {
                        text: qsTr("Minimize to tray on close")
                        checkable: true
                        checked: root.minimizeToTray
                        enabled: root.appConfig !== null
                        onToggled: root.setMinimizeToTray(checked)
                    }

                    Controls.MenuSeparator {}

                    Controls.MenuItem {
                        text: qsTr("Quit kIRC")
                        icon.name: "application-exit"
                        // Qt.quit() ends the application without going through
                        // the window close handler, so it is a real quit even
                        // with hide-to-tray enabled.
                        onTriggered: Qt.quit()
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
        kircConfig: root.appConfig

        onConnectRequested: (host, port, tls, nickname, saslUser, saslPass) => {
            // Remember what was attempted; persisted once the connection
            // actually succeeds (state 2 below). No password is kept.
            root.lastHost = host
            root.lastPort = port
            root.lastTls = tls
            root.lastNickname = nickname
            root.lastSaslUser = saslUser

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
                // connection was started from somewhere else, and persist the
                // profile that got us here.
                root.saveProfile()
                root.openChat()
            } else if (state === 0 && root.pageStack.depth > 1) {
                // Dropped: fall back to the connection form so the user can
                // retry. The bridge keeps the error detail.
                root.pageStack.pop()
            }
        }

        function onNotification_fired(title, body) {
            // In-app notice; the C++ side mirrors the same signal into a
            // native KNotification (cpp/kircnotify.cpp).
            root.showPassiveNotification(title.length > 0 ? (title + " — " + body) : body)
        }

        function onError_occurred(message) {
            root.showPassiveNotification(message, 5000)
        }

        // onInfo: intentional no handler — informational lines (MOTD,
        // numerics, joins/parts) are persisted to the *server* buffer in
        // the Rust bridge instead of transient popups.
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

    /// Persist the profile that just connected. host/port/tls/nickname and the
    /// SASL *username* only — never a password (kirc.conf is plaintext).
    function saveProfile()
    {
        if (root.appConfig === null || root.lastHost.length === 0) {
            return
        }
        root.appConfig.host = root.lastHost
        root.appConfig.port = root.lastPort
        root.appConfig.tls = root.lastTls
        root.appConfig.nickname = root.lastNickname
        root.appConfig.saslUser = root.lastSaslUser
        root.appConfig.save()
    }

    function setMinimizeToTray(enabled)
    {
        if (root.appConfig === null) {
            return
        }
        root.appConfig.minimizeToTray = enabled
        root.appConfig.save()
    }

    function trayVisibleLabel()
    {
        if (!root.trayAvailable) {
            return qsTr("Minimize to tray unavailable")
        }
        return root.visible ? qsTr("Hide to tray") : qsTr("Restore from tray")
    }

    function toggleToTray()
    {
        if (!root.trayAvailable) {
            return
        }
        if (root.visible) {
            root.hide()
        } else {
            root.show()
            root.raise()
            root.requestActivate()
        }
    }
}
