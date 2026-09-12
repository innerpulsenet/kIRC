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

// Bound ids: the compact ASCII header controls below are an inline component,
// which may reference the window's ids (root.*) like any nested component.
pragma ComponentBehavior: Bound

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
    // One monospace family for the whole window: controls inherit it unless
    // they set their own (the frozen `fontFamily` token).
    font.family: root.monoFamily

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

    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)

    // ---------------------------------------------------------------------- //
    // Retro-terminal chrome tokens (frozen ThemeEngine interface, consumed via
    // their resolvers). The header is monospace, flat and never hardcodes a
    // colour: an empty token means "use the desktop palette".
    // ---------------------------------------------------------------------- //
    readonly property string monoFamily: ThemeEngine.fontFamily
    readonly property color fgPrimary: ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
    readonly property color fgDim: ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
    readonly property color fgAccent: ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor)
    readonly property color fgWarn: ThemeEngine.fgWarnColor(Kirigami.Theme.negativeTextColor)
    readonly property color bgPanel: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color ruleC: ThemeEngine.ruleColorValue(root.hairline)
    readonly property color hoverFill: ThemeEngine.withAlpha(root.fgPrimary, 0.07)

    /// Colour tokens are strings that may be empty ("desktop palette"); the
    /// ThemeEngine resolvers above always return a usable colour, so the
    /// chrome never needs a literal colour.

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
    // IRC server password (PASS) for the current attempt/reconnects.  Memory
    // only — never persisted by the window (the settings pane owns KWallet).
    property string lastServerPass: ""
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

    /// Header status as bracketed terminal text: `[connected]` / `[connecting]`
    /// / `[offline]` — no rounded pill, no dot.
    readonly property string statusTag: {
        switch (root.bridge.connection_state) {
        case 0: return "[" + qsTr("offline") + "]"
        case 1: return "[" + qsTr("connecting") + "]"
        case 2: return "[" + qsTr("connected") + "]"
        }
        return "[" + qsTr("offline") + "]"
    }

    /// Header context line: the buffer as it is typed (`#pain`, a query nick,
    /// or the server console) — there is no coloured glyph tile any more.
    readonly property string headerContextText: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return root.headerTitle
        }
        if (root.chatChannel === "*server*") {
            return qsTr("Server")
        }
        return root.chatChannel
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
        ? root.fgAccent
        : (root.bridge.connection_state === 1
           ? root.fgDim
           : root.fgWarn)

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
    // Header: compact ASCII toolbar. Monospace context line, dim secondary
    // info, bracketed status text and flat `[action]` controls — the page
    // title and back control are re-created here (the default global toolbar
    // stays off).
    // ---------------------------------------------------------------------- //

    /// Flat text control for the header: bracketed ASCII label, accent on
    /// hover, no surface box. Keeps the ToolButton contract (text, tooltip,
    /// click) so every header action behaves exactly as before.
    component HeaderButton: Controls.ToolButton {
        id: headerButton
        display: Controls.AbstractButton.TextOnly
        Layout.alignment: Qt.AlignVCenter
        leftPadding: Kirigami.Units.smallSpacing
        rightPadding: Kirigami.Units.smallSpacing

        contentItem: Controls.Label {
            text: headerButton.text
            color: !headerButton.enabled ? root.fgDim
                   : (headerButton.hovered || headerButton.activeFocus ? root.fgAccent : root.fgPrimary)
            font.family: root.monoFamily
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            color: headerButton.hovered || headerButton.activeFocus ? root.hoverFill : "transparent"
        }
    }

    /// Flat terminal menu row.  The stock popup styling is a modern rounded
    /// light menu — against a black console it reads as a rendering bug, and
    /// its light-theme text colour can land dark-on-dark once the popup
    /// background is themed.
    component TermMenuItem: Controls.MenuItem {
        id: termItem
        font.family: root.monoFamily
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.55)
        // The stock check indicator paints from the item's left edge, which
        // lands on top of the first letter once contentItem is replaced — so
        // the mark is drawn as an ASCII checkbox inside the label instead.
        indicator: null
        background: Rectangle {
            color: termItem.highlighted || termItem.activeFocus ? root.hoverFill : "transparent"
        }
        contentItem: Controls.Label {
            leftPadding: Kirigami.Units.smallSpacing * 2
            rightPadding: Kirigami.Units.smallSpacing * 2
            text: termItem.checkable
                ? ((termItem.checked ? "[*] " : "[ ] ") + termItem.text)
                : termItem.text
            font: termItem.font
            color: termItem.enabled
                ? ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
                : ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    header: Controls.ToolBar {
        id: headerBar
        font.family: root.monoFamily

        background: Rectangle {
            color: root.bgPanel

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: root.ruleC
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            HeaderButton {
                text: "[" + qsTr("back") + "]"
                visible: root.pageStack.depth > 1
                onClicked: root.pageStack.pop()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Back to connection settings")
            }

            // Context: the buffer as it is typed (`#pain`, a query nick, or
            // the server console). The coloured glyph tile is gone.
            Controls.Label {
                text: root.headerContextText
                color: root.fgPrimary
                font.family: root.monoFamily
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                elide: Text.ElideRight
                Layout.fillWidth: true
                // Never elide below a readable floor: the title yields last.
                Layout.minimumWidth: Math.min(implicitWidth, Math.round(Kirigami.Units.gridUnit * 6))
                Layout.alignment: Qt.AlignVCenter
            }

            // Secondary line (nick @ server · topic), dim and truncating
            // gracefully. A fixed width cap keeps long topics from squeezing
            // the controls off the header; below a comfortable width the line
            // yields entirely so the channel title stays readable at the
            // minimum window size.
            Controls.Label {
                visible: root.headerSubtitle.length > 0
                         && root.width >= Kirigami.Units.gridUnit * 40
                text: root.headerSubtitle
                color: root.fgDim
                font.family: root.monoFamily
                font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 22
                Layout.alignment: Qt.AlignVCenter
            }

            // ---- connection status: bracketed terminal text ----
            Controls.Label {
                Layout.alignment: Qt.AlignVCenter
                text: root.statusTag
                color: root.statusColor
                font.family: root.monoFamily
                font.bold: true

                Accessible.name: root.statusTip
                Accessible.description: root.statusTip

                Controls.ToolTip.visible: statusHover.hovered
                Controls.ToolTip.text: root.statusTip

                HoverHandler {
                    id: statusHover
                }
            }

            // ---- unread count: `[3]`, opens/clears with the buffers ----
            // Count of unread messages across buffers; clears when the buffers
            // are read (ChatPage calls bridge.mark_read() on open/switch).
            Controls.Label {
                id: unreadLabel
                Layout.alignment: Qt.AlignVCenter
                // Only meaningful once the chat is on screen: on the connect
                // form a stale count from the previous session reads as a
                // mystery badge.
                visible: root.pageStack.depth > 1 && root.bridge.unread_count > 0
                text: "[" + (root.bridge.unread_count > 99 ? "99+" : root.bridge.unread_count) + "]"
                color: root.fgAccent
                font.family: root.monoFamily
                font.bold: true

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
            }

            // ---- own nick: plain text (no avatar chip) ----
            // Yields below a comfortable width, like the secondary line, so
            // the ASCII controls never get pushed out of the header.
            Controls.Label {
                Layout.alignment: Qt.AlignVCenter
                visible: root.bridge.nickname.length > 0
                         && root.width >= Kirigami.Units.gridUnit * 40
                text: root.bridge.nickname
                color: root.fgPrimary
                font.family: root.monoFamily
                elide: Text.ElideRight
                Layout.maximumWidth: Kirigami.Units.gridUnit * 8

                Accessible.name: root.bridge.nickname

                Controls.ToolTip.visible: nickHover.hovered
                Controls.ToolTip.text: root.bridge.nickname

                HoverHandler {
                    id: nickHover
                }
            }

            // Proper ASCII toolbar: Join (Ctrl+J), Search (Ctrl+F), Theme,
            // Settings, Disconnect, Menu — each with its tooltip.  (Search
            // forwards to the chat page when one is open; it is disabled on
            // the connection form.)
            HeaderButton {
                text: "[" + qsTr("join") + "]"
                // Chat actions only: hidden on the settings pane where they
                // would do nothing (the old layout showed a dead [join]).
                visible: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                enabled: root.pageStack.depth > 1 && root.bridge.connection_state === 2
                onClicked: root.requestChatJoin()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Join a channel (Ctrl+J)")
            }

            HeaderButton {
                id: searchButton
                text: "[" + qsTr("search") + "]"
                // Only where there is something to search: the settings pane
                // has no message search, so the button is hidden there instead
                // of being an enabled no-op.
                enabled: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                visible: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                onClicked: root.focusChatSearch()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Search messages (Ctrl+F)")
            }

            HeaderButton {
                id: settingsButton
                text: "[" + qsTr("settings") + "]"
                onClicked: root.openSettings()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Settings")
            }

            HeaderButton {
                id: disconnectButton
                text: "[" + qsTr("disconnect") + "]"
                visible: root.bridge.connection_state !== 0
                onClicked: {
                    root.userDisconnect = true
                    reconnectTimer.stop()
                    root.bridge.disconnect_server()
                }

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Disconnect")
            }

            // Theme picker: also reachable from the Settings pane when the
            // header is too narrow for the control.
            HeaderButton {
                id: themeButton
                text: "[" + qsTr("theme") + "]"
                visible: root.width >= Kirigami.Units.gridUnit * 36
                onClicked: themeMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Theme")

                Controls.Menu {
                    id: themeMenu
                    title: qsTr("Theme")
                    font.family: root.monoFamily
                    background: Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 12)
                        color: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
                        border.width: 1
                        border.color: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)
                    }

                    // Built-in (compiled-in) themes. Additional themes from
                    // ~/.config/kIRC/themes/ are appended by the C++ side, which
                    // is expected to extend ThemeEngine.availableThemeIds and
                    // call ThemeEngine.applyThemeJson() when one is picked.
                    Instantiator {
                        model: ThemeEngine.availableThemeIds

                        delegate: TermMenuItem {
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

            HeaderButton {
                id: appMenuButton
                text: "[" + qsTr("menu") + "]"
                onClicked: appMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Menu")

                Controls.Menu {
                    id: appMenu
                    font.family: root.monoFamily
                    background: Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 13)
                        color: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
                        border.width: 1
                        border.color: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)
                    }

                    TermMenuItem {
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

                    TermMenuItem {
                        text: qsTr("Join channel…")
                        icon.name: "list-add"
                        enabled: root.pageStack.depth > 1 && root.bridge.connection_state === 2
                        onTriggered: root.requestChatJoin()
                    }

                    Controls.MenuSeparator {}

                    TermMenuItem {
                        text: root.trayVisibleLabel()
                        icon.name: root.visible ? "window-minimize" : "window-restore"
                        enabled: root.trayAvailable
                        onTriggered: root.toggleToTray()
                    }

                    TermMenuItem {
                        text: qsTr("Minimize to tray on close")
                        checkable: true
                        checked: root.minimizeToTray
                        enabled: root.appConfig !== null
                        onToggled: root.setMinimizeToTray(checked)
                    }

                    TermMenuItem {
                        text: qsTr("Settings")
                        icon.name: "configure"
                        onTriggered: root.openSettings()
                    }

                    TermMenuItem {
                        text: qsTr("About kIRC")
                        icon.name: "help-about"
                        onTriggered: root.openAbout()
                    }

                    Controls.MenuSeparator {}

                    TermMenuItem {
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
        hostWindow: root

        // The form's SASL mechanism choice flows here (same 0/1/2 mapping).
        onConnectRequested: (host, port, tls, nickname, saslUser, saslPass, saslMechanism, serverPass) => {
            // Remember what was attempted; persisted once the connection
            // actually succeeds (state 2 below). The SASL password is kept in
            // memory only (never KConfig): reused by tryReconnect and handed
            // to the tray through sessionSaslPassword so a tray reconnect
            // does not SASL-904-loop.  The server password follows the same
            // rule (memory + sessionServerPassword for the tray).
            root.lastHost = host
            root.lastPort = port
            root.lastTls = tls
            root.lastNickname = nickname
            root.lastSaslUser = saslUser
            root.lastSaslPass = saslPass
            root.lastServerPass = (serverPass === undefined || serverPass === null) ? "" : serverPass
            root.lastSaslMechanism = (saslMechanism === undefined) ? root.saslMechanism : saslMechanism
            root.saslMechanism = root.lastSaslMechanism
            if (root.appConfig !== null && root.appConfig.sessionSaslPassword !== undefined) {
                root.appConfig.sessionSaslPassword = saslPass
            }
            if (root.appConfig !== null && root.appConfig.sessionServerPassword !== undefined) {
                root.appConfig.sessionServerPassword = root.lastServerPass
            }
            root.userDisconnect = false
            root.lastDropWasAuthFailure = false
            root.reconnectAttempt = 0
            reconnectTimer.stop()

            root.applySaslMechanism()
            root.applyServerPassword()
            root.applyCtcpVersionReply()
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
        root.applyServerPassword()
        root.applyCtcpVersionReply()
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

    /// Hand the IRC PASS password to the bridge.  Must run BEFORE
    /// connect_server (same contract as set_sasl_mechanism).  Guarded with
    /// typeof so a harness/double that predates the invokable keeps working;
    /// an empty password is skipped entirely.  When the connect form left the
    /// field empty, fall back to the KWallet-backed value from the settings
    /// pane (that is how a password stored in Settings reaches the connect).
    function applyServerPassword()
    {
        if (typeof root.bridge.set_server_password !== "function") {
            return
        }
        var password = root.lastServerPass
        if ((password === undefined || password === null || password.length === 0)
                && root.appConfig !== null && root.appConfig.serverPassword !== undefined) {
            password = String(root.appConfig.serverPassword)
        }
        if (password.length === 0) {
            return
        }
        root.bridge.set_server_password(password)
    }

    /// The persisted "reply to CTCP VERSION" preference (default on).
    /// Harnesses without prefs behave like the bridge default.
    function respondToCtcpVersion()
    {
        if (root.appConfig !== null && root.appConfig.respondToCtcpVersion !== undefined) {
            return root.appConfig.respondToCtcpVersion
        }
        return true
    }

    /// Hand the CTCP VERSION auto-reply choice to the bridge.  Must run BEFORE
    /// connect_server (same contract as set_sasl_mechanism) and on EVERY
    /// connect path, reconnects included: the bridge keeps the value for the
    /// session, so a dropped connection that is retried without this call
    /// would silently fall back to the default and start advertising the
    /// client again.  Guarded with typeof so older doubles keep working.
    function applyCtcpVersionReply()
    {
        if (typeof root.bridge.set_ctcp_version_reply !== "function") {
            return
        }
        root.bridge.set_ctcp_version_reply(root.respondToCtcpVersion())
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
            "kircConfig": root.appConfig,
            "hostWindow": root
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
