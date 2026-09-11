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

    // Icon theme id for the title bar / task switcher (set imperatively; the
    // QWindow icon property is dynamic on this Kirigami/Qt combo and rejects
    // a static assignment).
    // Window geometry is restored from the persisted prefs when present.
    width: 1024
    height: 700
    // qmllint disable missing-property
    Component.onCompleted: {
        try {
            if (root["icon"] !== undefined && root["icon"] !== null) {
                root["icon"].name = "kirc"
            }
        } catch (e) {
        }
        if (root.appConfig !== null) {
            root.restoreGeometry()
            root.syncSaslMechanismFromConfig()
            if (root.appConfig.themeId.length > 0) {
                ThemeEngine.applyBuiltinTheme(root.appConfig.themeId)
            }
            ThemeEngine.fontDelta = root.appConfig.fontDelta
        }
    }
    // qmllint enable missing-property
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
    property string lastSaslPass: ""
    property int lastSaslMechanism: 0
    property bool userDisconnect: false
    property int reconnectAttempt: 0
    // True when the last drop carried an authentication failure (904-907).
    // Cleared on every new attempt; when set, reconnects are skipped unless
    // the reconnectAfterAuthFailure pref allows them.
    property bool lastDropWasAuthFailure: false
    // The bridge-side SASL mechanism id currently in effect.  Initialised
    // from the persisted pref once (plain property + assignment, so no
    // binding loop with appConfig); written back when the user changes it.
    property int saslMechanism: 0

    function syncSaslMechanismFromConfig()
    {
        if (root.appConfig !== null && root.appConfig.saslMechanism !== undefined) {
            root.saslMechanism = root.appConfig.saslMechanism
        }
    }

    Timer {
        id: reconnectTimer
        interval: 3000
        repeat: false
        onTriggered: root.tryReconnect()
    }

    /// Buffer name for humans. "*server*" is internal; the header glyph
    /// already shows "#" for channels so the title drops the prefix.
    function channelLabel(target)
    {
        if (target === "*server*") {
            return qsTr("Server")
        }
        if (target.length > 1 && root.isChannel(target)) {
            return target.substring(1)
        }
        return target
    }

    readonly property bool currentIsQuery: {
        var t = root.chatChannel
        return t.length > 0 && t !== "*server*" && !root.isChannel(t)
    }

    /// Channel prefixes (# & + !). Mirrors ChatPage.isChannel for the header.
    function isChannel(target)
    {
        if (target === undefined || target === null || target === "*server*") {
            return false
        }
        var c = String(target).charAt(0)
        return c === "#" || c === "&" || c === "+" || c === "!"
    }

    // Header/window title.  The settings pane is not a chat buffer, so it
    // names itself instead of borrowing the channel label.
    readonly property string headerTitle: root.pageStack.depth <= 1
        ? qsTr("Connect to IRC")
        : (root.currentPageIsSettings() ? qsTr("Settings")
                                        : root.channelLabel(root.chatChannel))

    function currentPageIsSettings()
    {
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        return page !== null && page !== undefined && page["isKircSettingsPage"] === true
        // qmllint enable missing-property
    }

    readonly property string statusText: {
        switch (root.bridge.connection_state) {
        case 0: return qsTr("Disconnected")
        case 1: return qsTr("Connecting…")
        case 2: return qsTr("Connected")
        }
        return qsTr("Disconnected")
    }

    // Secondary header line: nick @ server, plus the channel topic when one
    // is known.  Derived from live bridge state + the chat page below; empty
    // when there is nothing useful to say (connection form, settings pane).
    readonly property string headerSubtitle: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return ""
        }
        var bits = []
        var nick = root.bridge.nickname
        var server = root.bridge.connected_server
        if (nick.length > 0 && server.length > 0) {
            var cut = server.indexOf(":")
            var shortServer = cut > 0 ? server.substring(0, cut) : server
            bits.push(nick + " @ " + shortServer)
        } else if (nick.length > 0) {
            bits.push(nick)
        } else if (server.length > 0) {
            bits.push(server)
        }
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        if (page && page["currentTopic"] !== undefined && String(page["currentTopic"]).length > 0
                && root.isChannel(root.chatChannel)) {
            bits.push(String(page["currentTopic"]))
        }
        // qmllint enable missing-property
        return bits.join(" · ")
    }

    // Tooltip for the connection status pill ("Connected to …" etc).
    readonly property string statusTip: {
        var server = root.bridge.connected_server
        switch (root.bridge.connection_state) {
        case 2: return server.length > 0 ? qsTr("Connected to %1").arg(server) : qsTr("Connected")
        case 1: return server.length > 0 ? qsTr("Connecting to %1…").arg(server) : qsTr("Connecting…")
        }
        return server.length > 0 ? qsTr("Disconnected from %1").arg(server) : qsTr("Disconnected")
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
    // window close.  The geometry is persisted first, so a re-launch restores
    // the size the user actually closed with.
    onClosing: (close) => {
        root.saveGeometry()
        if (root.trayAvailable && root.minimizeToTray) {
            close.accepted = false
            root.hide()
        }
    }

    onWidthChanged: saveGeometrySoon()
    onHeightChanged: saveGeometrySoon()

    // Coalesced geometry writer: stores the live size (not while hidden to
    // tray) so a restart restores it.
    Timer {
        id: geometryTimer
        interval: 500
        repeat: false
        onTriggered: root.saveGeometry()
    }

    function saveGeometrySoon()
    {
        if (root.appConfig === null || !root.visible) {
            return
        }
        geometryTimer.restart()
    }

    function saveGeometry()
    {
        if (root.appConfig === null || root.appConfig.windowWidth === undefined) {
            return
        }
        if (root.width >= root.minimumWidth && root.height >= root.minimumHeight) {
            root.appConfig.windowWidth = root.width
            root.appConfig.windowHeight = root.height
            root.appConfig.save()
        }
    }

    // ---------------------------------------------------------------------- //
    // Restored geometry.  The persisted size is a *hint*: a stale entry may
    // predate the current minimums, or come from a larger display.  Clamping
    // it to [minimum, available screen] is what keeps the composer and the
    // header from being clipped by a window the layout cannot fit into.
    // ---------------------------------------------------------------------- //

    /// Work area of the window's screen in logical pixels; {0, 0} when the
    /// platform reports no screen (offscreen harnesses).
    function maximumWindowSize()
    {
        var result = {"width": 0, "height": 0}
        var screen = root.screen
        if (screen === undefined || screen === null) {
            return result
        }
        // Qt 6 exposes the work area (panels excluded) as desktopAvailable*.
        // Those are device pixels, while the window is laid out in logical
        // pixels, so scale by the device pixel ratio.
        var w = (screen.desktopAvailableWidth !== undefined && screen.desktopAvailableWidth > 0)
            ? screen.desktopAvailableWidth : screen.width
        var h = (screen.desktopAvailableHeight !== undefined && screen.desktopAvailableHeight > 0)
            ? screen.desktopAvailableHeight : screen.height
        var dpr = (screen.devicePixelRatio > 0) ? screen.devicePixelRatio : 1
        if (w > 0 && h > 0) {
            result.width = Math.round(w / dpr)
            result.height = Math.round(h / dpr)
        }
        return result
    }

    /// Clamp one window dimension to [minimum, maximum]; -1 means "no usable
    /// stored value", which leaves the current size alone.
    function clampWindowDimension(value, minimum, maximum)
    {
        if (value === undefined || value === null || isNaN(value) || value <= 0) {
            return -1
        }
        var v = Math.round(value)
        if (maximum > 0 && v > maximum) {
            v = maximum
        }
        // The minimum wins even on a screen smaller than it: a window whose
        // own layout clips is worse than one the window manager must move.
        return Math.max(minimum, v)
    }

    function restoreGeometry()
    {
        if (root.appConfig === null || root.appConfig.windowWidth === undefined) {
            return
        }
        var screenMax = root.maximumWindowSize()
        var w = root.clampWindowDimension(root.appConfig.windowWidth, root.minimumWidth, screenMax.width)
        var h = root.clampWindowDimension(root.appConfig.windowHeight, root.minimumHeight, screenMax.height)
        if (w > 0) {
            root.width = w
        }
        if (h > 0) {
            root.height = h
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
                    text: root.currentIsQuery ? ThemeEngine.initial(root.chatChannel) : "#"
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

            // Secondary line (nick @ server · topic), truncating gracefully.
            // A fixed width cap keeps long topics from squeezing the pills
            // and toolbar off the header; below a comfortable width the line
            // yields entirely so the channel title stays readable at the
            // minimum window size.
            Controls.Label {
                visible: root.headerSubtitle.length > 0
                         && root.width >= Kirigami.Units.gridUnit * 40
                text: root.headerSubtitle
                color: Kirigami.Theme.disabledTextColor
                font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            }

            // ---- connection status pill ----
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: statusPill.implicitWidth + Kirigami.Units.smallSpacing * 2
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.5)
                radius: height / 2
                color: ThemeEngine.withAlpha(root.statusColor, 0.16)

                Accessible.name: root.statusTip
                Accessible.description: root.statusTip

                Controls.ToolTip.visible: statusHover.hovered
                Controls.ToolTip.text: root.statusTip

                HoverHandler {
                    id: statusHover
                }

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

            // ---- unread badge: opens/clears with the buffers ----
            // Count of unread messages across buffers; clears when the buffers
            // are read (ChatPage calls bridge.mark_read() on open/switch).
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                // Only meaningful once the chat is on screen: on the connect
                // form a stale count from the previous session reads as a
                // mystery badge.
                visible: root.pageStack.depth > 1 && root.bridge.unread_count > 0
                implicitWidth: Math.max(height, unreadLabel.implicitWidth + Kirigami.Units.smallSpacing * 2)
                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.5)
                radius: height / 2
                color: Kirigami.Theme.highlightColor

                Accessible.name: qsTr("%n unread message(s)", "", root.bridge.unread_count)
                Accessible.description: qsTr("Unread messages")

                Controls.ToolTip.visible: unreadHover.hovered
                Controls.ToolTip.text: qsTr("%n unread message(s)", "", root.bridge.unread_count)

                HoverHandler {
                    id: unreadHover
                }

                TapHandler {
                    onTapped: {
                        if (root.pageStack.depth > 1
                                && typeof root.bridge.mark_read === "function") {
                            root.bridge.mark_read()
                        }
                    }
                }

                Controls.Label {
                    id: unreadLabel
                    anchors.centerIn: parent
                    text: root.bridge.unread_count > 99 ? "99+" : root.bridge.unread_count
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

                Accessible.name: root.bridge.nickname

                Controls.ToolTip.visible: nickHover.hovered
                Controls.ToolTip.text: root.bridge.nickname

                HoverHandler {
                    id: nickHover
                }

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

            // Proper toolbar: Search (Ctrl+F), Settings, Menu — each labelled
            // with a tooltip.  (Search forwards to the chat page when one is
            // open; it is disabled on the connection form.)
            Controls.ToolButton {
                id: searchButton
                icon.name: "edit-find"
                text: qsTr("Search")
                display: Controls.AbstractButton.IconOnly
                enabled: root.pageStack.depth > 1
                visible: root.pageStack.depth > 1
                onClicked: root.focusChatSearch()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Search messages (Ctrl+F)")
            }

            Controls.ToolButton {
                id: settingsButton
                icon.name: "configure"
                text: qsTr("Settings")
                display: Controls.AbstractButton.IconOnly
                onClicked: root.openSettings()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Settings")
            }

            Controls.ToolButton {
                id: disconnectButton
                icon.name: "network-disconnect"
                text: qsTr("Disconnect")
                display: Controls.AbstractButton.IconOnly
                visible: root.bridge.connection_state !== 0
                onClicked: {
                    root.userDisconnect = true
                    reconnectTimer.stop()
                    root.bridge.disconnect_server()
                }

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
                            onTriggered: {
                                ThemeEngine.applyBuiltinTheme(themeItem.modelData)
                                if (root.appConfig !== null) {
                                    root.appConfig.themeId = themeItem.modelData
                                    root.appConfig.save()
                                }
                            }
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
                        text: root.bridge.connection_state === 0 ? qsTr("Connect") : qsTr("Disconnect")
                        icon.name: root.bridge.connection_state === 0 ? "network-connect" : "network-disconnect"
                        onTriggered: {
                            if (root.bridge.connection_state === 0) {
                                if (root.pageStack.depth > 1) {
                                    root.pageStack.pop()
                                }
                            } else {
                                root.userDisconnect = true
                                reconnectTimer.stop()
                                root.bridge.disconnect_server()
                            }
                        }
                    }

                    Controls.MenuItem {
                        text: qsTr("Join channel…")
                        icon.name: "list-add"
                        enabled: root.pageStack.depth > 1 && root.bridge.connection_state === 2
                        onTriggered: root.requestChatJoin()
                    }

                    Controls.MenuSeparator {}

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

                    Controls.MenuItem {
                        text: qsTr("Settings")
                        icon.name: "configure"
                        onTriggered: root.openSettings()
                    }

                    Controls.MenuItem {
                        text: qsTr("About kIRC")
                        icon.name: "help-about"
                        onTriggered: root.openAbout()
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

    // Global shortcuts: Search (Ctrl+F), Join channel (Ctrl+J), Settings.
    // Top-level Shortcut items — ToolButton/MenuItem have no shortcut prop.
    Shortcut {
        sequence: "Ctrl+F"
        enabled: root.pageStack.depth > 1
        onActivated: root.focusChatSearch()
    }

    Shortcut {
        sequence: "Ctrl+J"
        enabled: root.pageStack.depth > 1 && root.bridge.connection_state === 2
        onActivated: root.requestChatJoin()
    }

    Shortcut {
        sequence: StandardKey.Preferences
        onActivated: root.openSettings()
    }

    // ---------------------------------------------------------------------- //
    // Page stack
    // ---------------------------------------------------------------------- //
    pageStack.initialPage: ConnectPage {
        bridge: root.bridge
        kircConfig: root.appConfig

        // The form's SASL mechanism choice flows here (same 0/1/2 mapping).
        onConnectRequested: (host, port, tls, nickname, saslUser, saslPass, saslMechanism) => {
            // Remember what was attempted; persisted once the connection
            // actually succeeds (state 2 below). The SASL password is kept in
            // memory only (never KConfig): reused by tryReconnect and handed
            // to the tray through sessionSaslPassword so a tray reconnect
            // does not SASL-904-loop.
            root.lastHost = host
            root.lastPort = port
            root.lastTls = tls
            root.lastNickname = nickname
            root.lastSaslUser = saslUser
            root.lastSaslPass = saslPass
            root.lastSaslMechanism = (saslMechanism === undefined) ? root.saslMechanism : saslMechanism
            root.saslMechanism = root.lastSaslMechanism
            if (root.appConfig !== null && root.appConfig.sessionSaslPassword !== undefined) {
                root.appConfig.sessionSaslPassword = saslPass
            }
            root.userDisconnect = false
            root.lastDropWasAuthFailure = false
            root.reconnectAttempt = 0
            reconnectTimer.stop()

            root.applySaslMechanism()
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
                root.reconnectAttempt = 0
                root.lastDropWasAuthFailure = false
                reconnectTimer.stop()
                root.saveProfile()
                root.openChat()
            } else if (state === 0) {
                if (!root.userDisconnect && root.wantReconnect() && root.lastHost.length > 0) {
                    // Never retry an authentication failure unless the user
                    // opted in: a bad password would otherwise 904-loop, and
                    // the tray honors the same policy (KircTray::onConnect is
                    // only reached from an explicit click).
                    if (root.lastDropWasAuthFailure && !root.reconnectAfterAuthFailureAllowed()) {
                        root.lastDropWasAuthFailure = false
                        if (root.pageStack.depth > 1) {
                            root.pageStack.pop()
                        }
                        return
                    }
                    var limit = root.reconnectLimit()
                    if (limit > 0 && root.reconnectAttempt >= limit) {
                        if (root.pageStack.depth > 1) {
                            root.pageStack.pop()
                        }
                        return
                    }
                    reconnectTimer.interval = Math.min(30000, 3000 * Math.pow(2, root.reconnectAttempt))
                    root.reconnectAttempt += 1
                    reconnectTimer.start()
                    return
                }
                if (root.pageStack.depth > 1) {
                    root.pageStack.pop()
                }
            }
        }

        function onNotification_fired(title, body) {
            // Native KNotification is the C++ side's job (cpp/kircnotify.cpp);
            // the in-app notice is gated here on the notification prefs.
            if (!root.notificationsAllowed(title)) {
                return
            }
            root.showPassiveNotification(title.length > 0 ? (title + " — " + body) : body)
        }

        function onError_occurred(message) {
            if (root.looksLikeAuthFailure(message)) {
                root.lastDropWasAuthFailure = true
            }
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

    function tryReconnect()
    {
        if (root.userDisconnect || root.lastHost.length === 0) {
            return
        }
        root.applySaslMechanism()
        root.bridge.connect_server(root.lastHost, root.lastPort, root.lastTls,
                                   root.lastNickname, root.lastSaslUser, root.lastSaslPass)
    }

    function wantReconnect()
    {
        return root.appConfig !== null && root.appConfig.reconnect
    }

    /// Max automatic reconnect attempts (0 = unlimited).  Defaults to 10 so
    /// a dead network cannot retry forever; harnesses without prefs behave
    /// as unlimited.
    function reconnectLimit()
    {
        if (root.appConfig !== null && root.appConfig.reconnectLimit !== undefined) {
            return root.appConfig.reconnectLimit
        }
        return 0
    }

    /// Whether an authentication-failure drop may be retried.  Off unless the
    /// user opts in, so a bad SASL/NickServ password never loops.
    function reconnectAfterAuthFailureAllowed()
    {
        if (root.appConfig !== null && root.appConfig.reconnectAfterAuthFailure !== undefined) {
            return root.appConfig.reconnectAfterAuthFailure
        }
        return false
    }

    /// True when `message` looks like a SASL/authentication failure (904-907,
    /// "authentication failed", NickServ "invalid password" / "not registered").
    function looksLikeAuthFailure(message)
    {
        if (message === undefined || message === null) {
            return false
        }
        var m = String(message).toLowerCase()
        return m.indexOf("904") >= 0 || m.indexOf("905") >= 0
            || m.indexOf("906") >= 0 || m.indexOf("907") >= 0
            || m.indexOf("sasl authentication failed") >= 0
            || m.indexOf("authentication failed") >= 0
            || m.indexOf("invalid password") >= 0
            || m.indexOf("password incorrect") >= 0
            || m.indexOf("not registered") >= 0
    }

    /// Gate for notification_fired: highlights need notifyHighlights, a
    /// private-message title (a nick, not a #channel) needs
    /// notifyDirectMessages.  Harnesses without prefs allow everything.
    function notificationsAllowed(title)
    {
        if (root.appConfig === null) {
            return true
        }
        var highlights = root.appConfig.notifyHighlights
        var directs = root.appConfig.notifyDirectMessages
        if (highlights === undefined && directs === undefined) {
            return true
        }
        var t = String(title === undefined || title === null ? "" : title)
        var isChannel = t.length > 0 && (t.charAt(0) === "#" || t.charAt(0) === "&"
                      || t.charAt(0) === "+" || t.charAt(0) === "!")
        if (isChannel) {
            return highlights === undefined ? true : highlights
        }
        // Private message (or untitled notice): both prefs apply.
        if (highlights !== undefined && !highlights) {
            return false
        }
        return directs === undefined ? true : directs
    }

    /// Push the persisted SASL mechanism into the bridge.  Must run BEFORE
    /// connect_server (bridge contract).  Guarded with typeof so harnesses
    /// whose stub predates set_sasl_mechanism keep working.
    function applySaslMechanism()
    {
        if (typeof root.bridge.set_sasl_mechanism !== "function") {
            return
        }
        root.bridge.set_sasl_mechanism(root.saslMechanism)
    }

    /// Open the chat page's join dialog when it exists; otherwise drive the
    /// chat page's own join entry (both owned by ChatPage, guarded by
    /// typeof so harnesses without them keep working).
    // qmllint disable missing-property
    function requestChatJoin()
    {
        var page = root.pageStack.currentItem
        if (page) {
            if (typeof page["openJoinDialog"] === "function") {
                page["openJoinDialog"]()
                return
            }
            // Older ChatPage without the dialog: drive its join entry when
            // present (it sends JOIN via the bridge itself).
            if (typeof page["tryJoin"] === "function") {
                page["tryJoin"]()
                return
            }
        }
    }
    // qmllint enable missing-property

    /// Give the chat page's search field focus (Ctrl+F toolbar action).
    /// No-op when no chat page is open or it has no search UI.
    // qmllint disable missing-property
    function focusChatSearch()
    {
        var page = root.pageStack.currentItem
        if (page && typeof page["focusSearch"] === "function") {
            page["focusSearch"]()
        }
    }
    // qmllint enable missing-property

    /// Push the settings pane (single instance: pop back to it if open).
    function openSettings()
    {
        for (var i = 0; i < root.pageStack.depth; ++i) {
            var item = root.pageStack.get(i)
            if (item && item.isKircSettingsPage) {
                while (root.pageStack.depth - 1 > i) {
                    root.pageStack.pop()
                }
                return
            }
        }
        root.pageStack.push(Qt.resolvedUrl("SettingsPage.qml"), {
            "kircConfig": root.appConfig
        })
    }

    /// The About content lives in the settings pane's About section.
    // qmllint disable missing-property
    function openAbout()
    {
        root.openSettings()
        var page = root.pageStack.currentItem
        if (page && typeof page["showAbout"] === "function") {
            page["showAbout"]()
        }
    }
    // qmllint enable missing-property

    function closeCurrentBuffer()
    {
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        if (page && page["closeBuffer"]) {
            page["closeBuffer"](root.chatChannel)
        }
        // qmllint enable missing-property
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
