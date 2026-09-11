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
//
// The page stack is forced into single-column mode (`defaultColumnWidth`): a
// chat client should show one page at a time — PageRow's side-by-side desktop
// layout used to leave the connection form visible next to the chat log.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirigami.layouts as KirigamiLayouts
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
    property string chatChannel: "*server*"

    // One page at a time. PageRow otherwise switches to FixedColumns in
    // wideMode and leaves the connect form sitting beside (or ghosting
    // through) the chat log.
    pageStack.defaultColumnWidth: root.width
    pageStack.columnView.columnResizeMode: KirigamiLayouts.ColumnView.SingleColumn

    // The window provides its own header below; without this the PageRow draws
    // a second toolbar (breadcrumb + navigation) underneath it.
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)

    // ---------------------------------------------------------------------- //
    // Persisted profile (KircConfig). `appConfig` is null in harnesses that do
    // not provide the context property.
    //
    // `kircConfig` / `kircTray` are C++ context properties (cpp/kircconfig.cpp,
    // cpp/kirctray.cpp); the existence checks are what let this file also load
    // in the standalone QML harnesses, which is why the unqualified-access lint
    // category is disabled around them.
    // ---------------------------------------------------------------------- //
    // qmllint disable unqualified
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
    // qmllint enable unqualified

    // Last connection attempt, captured so a *successful* connect can be
    // persisted (the bridge owns the real state; this is just what the user
    // typed).
    property string lastHost: ""
    property int lastPort: 0
    property bool lastTls: true
    property string lastNickname: ""
    property string lastSaslUser: ""

    /// Buffer name for humans. "*server*" is internal; the header glyph
    /// already shows "#" for channels so the title drops the prefix.
    function channelLabel(target)
    {
        if (target === "*server*") {
            return qsTr("Server")
        }
        if (target.length > 1 && target.charAt(0) === "#") {
            return target.substring(1)
        }
        return target
    }

    readonly property string headerTitle: root.pageStack.depth > 1
        ? root.channelLabel(root.chatChannel)
        : qsTr("Connect to IRC")

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
    // Header: current context + connection status pill + nick chip + flat menu
    // buttons. Replaces the default global toolbar, so the page title and a
    // back button are re-created here.
    // ---------------------------------------------------------------------- //
    header: Controls.ToolBar {
        id: headerBar

        background: Rectangle {
            color: Kirigami.Theme.backgroundColor

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: root.hairline
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
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

            // Context glyph: the channel's own hash colour, or a server
            // pictogram for the "*server*" console buffer.
            Rectangle {
                visible: root.pageStack.depth > 1
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.35)
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.35)
                radius: Kirigami.Units.cornerRadius
                color: root.chatChannel === "*server*"
                    ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
                    : ThemeEngine.nickColor(root.chatChannel, root.darkTheme)

                Kirigami.Icon {
                    anchors.centerIn: parent
                    visible: root.chatChannel === "*server*"
                    source: "network-server"
                    color: Kirigami.Theme.textColor
                    implicitWidth: Math.round(parent.width * 0.66)
                    implicitHeight: implicitWidth
                }

                Controls.Label {
                    anchors.centerIn: parent
                    visible: root.chatChannel !== "*server*"
                    text: "#"
                    color: ThemeEngine.contrastingTextColor(parent.color)
                    font.bold: true
                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize)
                }
            }

            Controls.Label {
                text: root.headerTitle
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // ---- connection status pill ----
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: statusPill.implicitWidth + Kirigami.Units.smallSpacing * 2
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.5)
                radius: height / 2
                color: ThemeEngine.withAlpha(root.statusColor, 0.16)

                RowLayout {
                    id: statusPill
                    anchors.centerIn: parent
                    spacing: Math.round(Kirigami.Units.smallSpacing * 0.75)

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 0.45)
                        implicitHeight: implicitWidth
                        radius: width / 2
                        color: root.statusColor
                    }

                    Controls.Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: root.statusText
                        color: root.statusColor
                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                    }
                }
            }

            // ---- unread badge ----
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                visible: root.bridge.unread_count > 0
                implicitWidth: Math.max(height, unreadLabel.implicitWidth + Kirigami.Units.smallSpacing * 2)
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.5)
                radius: height / 2
                color: Kirigami.Theme.highlightColor

                Controls.Label {
                    id: unreadLabel
                    anchors.centerIn: parent
                    text: root.bridge.unread_count
                    color: Kirigami.Theme.highlightedTextColor
                    font.bold: true
                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                }
            }

            // ---- nick chip ----
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                visible: root.bridge.nickname.length > 0
                implicitWidth: nickChip.implicitWidth + Kirigami.Units.smallSpacing * 2
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
                radius: height / 2
                color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.07)

                RowLayout {
                    id: nickChip
                    anchors.centerIn: parent
                    spacing: Math.round(Kirigami.Units.smallSpacing * 0.75)

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.05)
                        implicitHeight: implicitWidth
                        radius: width / 2
                        color: ThemeEngine.nickColor(root.bridge.nickname, root.darkTheme)

                        Controls.Label {
                            anchors.centerIn: parent
                            text: ThemeEngine.initial(root.bridge.nickname)
                            color: ThemeEngine.contrastingTextColor(parent.color)
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 2)
                        }
                    }

                    Controls.Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: root.bridge.nickname
                        color: Kirigami.Theme.textColor
                        elide: Text.ElideRight
                        Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                    }
                }
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
