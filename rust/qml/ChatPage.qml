// SPDX-License-Identifier: GPL-2.0-or-later
//
// ChatPage — channel sidebar + message view + input line.
//
// Bridge contract used here (cxx-qt keeps snake_case ids in QML):
//   IrcBridge:        connection_state, unread_count, nickname, connected_server
//                     signals: message_received(target, nick, text, timestamp,
//                                                is_self, is_highlight),
//                              history_batch_received(target), state_changed(state),
//                              notification_fired(title, body), info(text),
//                              error_occurred(message)
//                     invokables: connect_server(...), disconnect_server(),
//                                 send_message(target, text), request_history(target, limit)
//   MessageListModel: roles nick, text, timestamp, isSelf, isHighlight
//                     invokables: load_channel(target) — full reload; used for
//                                 buffer switches and history batches only
//                                 append_message(target, nick, text, timestamp,
//                                                isSelf, isHighlight) — incremental
//                                 insert for the live path; no-op unless
//                                 `target` is the loaded buffer
//
// Layout (left to right): sidebar (header actions + Server / Messages /
// Channels sections), hairline, message column (topic bar, log with a
// new-messages pill, input bar with an inline server-console hint), and an
// optional people panel for channels.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.kirc

pragma ComponentBehavior: Bound

Kirigami.Page {
    id: page

    // Set by main.qml.
    property var bridge: null
    // The ApplicationWindow, so the header title can follow the active channel.
    property var hostWindow: null

    readonly property int timestampPointSize: ThemeEngine.resolvePointSize(ThemeEngine.timestampSize, Kirigami.Theme.defaultFont.pointSize)
    readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
    readonly property bool connected: page.bridge !== null && page.bridge.connection_state === 2
    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)

    // Label of the "*server*" buffer row: the network we are actually on when
    // connected, so it never just repeats the "Server" section header.
    readonly property string serverBufferLabel: {
        var server = (page.bridge !== null && page.bridge.connected_server !== undefined)
            ? page.bridge.connected_server : ""
        if (server.length === 0) {
            return qsTr("Server console")
        }
        var cut = server.indexOf(":")
        return cut > 0 ? server.substring(0, cut) : server
    }

    property string currentChannel: "*server*"
    // Only buffers the server has actually accepted (plus the console and
    // query windows). #kirc is NOT auto-joined.
    property var channels: ["*server*"]
    property string currentTopic: ""
    property var nickList: []
    property string joinError: ""
    property var pendingJoins: []
    property bool autojoinDone: false
    // Guards the post-identify GHOST+NICK reclaim: once per connection.
    property bool ghostDone: false
    // People panel visibility + live filter, and the topic bar's expand state.
    property bool peopleVisible: true
    /// Space (right of the sidebar) the people panel needs before it is worth
    /// showing: its own ~198px plus a log column that is still readable.
    readonly property real peoplePanelMinSpace: 560
    property string peopleFilter: ""
    property bool topicExpanded: false
    // The user scrolled up and traffic arrived below: offer a way back down.
    property bool hasUnseenBelow: false

    title: page.channelLabel(page.currentChannel)
    padding: 0

    /// "*server*" is a buffer name, not something to show the user verbatim.
    function channelLabel(target)
    {
        if (target === "*server*") {
            return qsTr("Server")
        }
        return target
    }

    // ---------------------------------------------------------------------- //
    // Theme surfaces (via ThemeEngine's flat tokens + resolvers; empty theme
    // strings fall back to the Kirigami palette at the call site).
    // ---------------------------------------------------------------------- //
    readonly property real sideWidth: ThemeEngine.sidebarWidth > 0 ? ThemeEngine.sidebarWidth : 250
    readonly property color sideBg: ThemeEngine.sidebarSurfaceColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color panelBg: ThemeEngine.surfaceAltColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property real rowHt: ThemeEngine.rowHeight
    readonly property real rowRad: ThemeEngine.rowRadius
    readonly property color rowHv: ThemeEngine.rowHoverColor(ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.08))
    readonly property color rowSel: ThemeEngine.rowSelectedColor(ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.28))
    readonly property color accentC: ThemeEngine.accentColor(Kirigami.Theme.highlightColor)
    readonly property color accentTxt: ThemeEngine.accentTextColor(Kirigami.Theme.highlightedTextColor)
    readonly property color mutedTxt: ThemeEngine.mutedTextColor(Kirigami.Theme.disabledTextColor)
    readonly property color sectionTxt: ThemeEngine.sectionHeaderColor(Kirigami.Theme.textColor)
    readonly property int sectionSz: ThemeEngine.resolveSectionHeaderSize(Kirigami.Theme.defaultFont.pointSize)
    readonly property color eventTxt: ThemeEngine.eventTextColor(Kirigami.Theme.disabledTextColor)
    readonly property int eventSz: ThemeEngine.resolveEventSize(Kirigami.Theme.defaultFont.pointSize)
    readonly property color onlineC: ThemeEngine.statusOnlineColor(Kirigami.Theme.positiveTextColor)
    readonly property color awayC: ThemeEngine.statusAwayColor(Kirigami.Theme.neutralTextColor)
    readonly property color offlineC: ThemeEngine.statusOfflineColor(Kirigami.Theme.disabledTextColor)
    readonly property color unreadBg: ThemeEngine.unreadBadgeColor(Kirigami.Theme.highlightColor)
    readonly property color unreadTxt: ThemeEngine.unreadBadgeTextColor(Kirigami.Theme.highlightedTextColor)
    readonly property real inputRad: ThemeEngine.inputRadius

    // ---------------------------------------------------------------------- //
    // Model
    // ---------------------------------------------------------------------- //
    MessageListModel {
        id: msgModel
    }

    // NickServ IDENTIFY grace period: if no confirmation arrives, retry the
    // joins anyway (the handle-identify join flow below).
    Timer {
        id: identifyTimer
        interval: 4000
        repeat: false
        onTriggered: page.applyAutojoin()
    }

    Connections {
        target: page.bridge

        function onMessage_received(target, nick, text, timestamp, is_self, is_highlight) {
            if (page.sameTarget(target, page.currentChannel)) {
                // Incremental append: the bridge already stored the row, so
                // this is one begin/endInsertRows instead of a whole-buffer
                // model reset per line.  A line for any other buffer is a
                // no-op inside the model and shows up when it is opened.
                // Autoscroll stays conditional: pin to the bottom only when
                // the view is already there or the line is our own echo —
                // never yank a user who scrolled up to read.
                var stick = is_self || messageView.atYEnd
                msgModel.append_message(target, nick, text, timestamp, is_self, is_highlight)
                if (stick) {
                    page.hasUnseenBelow = false
                    page.scrollToEnd()
                } else {
                    page.hasUnseenBelow = true
                }
            }
            if (!is_self && page.isNickServ(nick) && page.isIdentifySuccess(text)) {
                identifyTimer.stop()
                page.maybeGhost()
                page.applyAutojoin()
            }
        }

        function onHistory_batch_received(target) {
            if (page.sameTarget(target, page.currentChannel)) {
                page.refreshHistory()
                page.scrollIfAtBottom()
            }
        }

        function onState_changed(state) {
            if (state === 2) {
                page.autojoinDone = false
                page.ghostDone = false
                page.refreshHistory()
                page.startIdentifyAndJoin()
            } else if (state === 0) {
                page.autojoinDone = false
                page.ghostDone = false
                page.pendingJoins = []
                identifyTimer.stop()
                page.channels = ["*server*"]
                page.nickList = []
                page.currentTopic = ""
                page.openChannel("*server*")
            }
        }

        function onChannel_joined(channel) {
            page.forgetPendingJoin(channel)
            page.addBuffer(channel)
            page.openChannel(channel)
            if (page.bridge !== null) {
                page.bridge.request_history(channel, 200)
            }
            page.joinError = ""
        }

        function onChannel_parted(channel) {
            page.removeBuffer(channel)
            if (page.sameTarget(page.currentChannel, channel)) {
                page.openChannel("*server*")
            }
        }

        function onJoin_failed(channel, reason) {
            page.rememberPendingJoin(channel)
            page.removeBuffer(channel)
            page.joinError = reason
            if (page.hostWindow !== null && page.hostWindow.showPassiveNotification) {
                page.hostWindow.showPassiveNotification(reason, 5000)
            }
        }

        function onTopic_changed(channel, topic) {
            if (page.sameTarget(channel, page.currentChannel)) {
                page.currentTopic = topic
            }
        }

        function onNames_updated(channel, nicks) {
            if (page.sameTarget(channel, page.currentChannel)) {
                page.nickList = nicks.length === 0 ? [] : nicks.split(" ")
            }
        }

        function onQuery_opened(nick) {
            page.addBuffer(nick)
            page.foldDuplicateBuffers()
        }
    }

    // ---------------------------------------------------------------------- //
    // Sidebar buffers
    // ---------------------------------------------------------------------- //
    /// The sidebar renders this derived list rather than `channels` directly:
    /// every entry already carries its label, kind and "start of section" flag,
    /// so no delegate has to look up its neighbours — the view's `index` is not
    /// readable through a delegate on Qt 6.11.
    readonly property var buffers: {
        var channelCount = 0
        var queryCount = 0
        var k
        for (k = 0; k < page.channels.length; ++k) {
            var t = page.channels[k]
            if (t === "*server*") {
                continue
            }
            if (page.isChannel(t)) {
                channelCount += 1
            } else {
                queryCount += 1
            }
        }
        var out = []
        var previousKind = ""
        for (var i = 0; i < page.channels.length; ++i) {
            var target = page.channels[i]
            var isServer = (target === "*server*")
            var isChan = !isServer && page.isChannel(target)
            var isQuery = !isServer && !isChan
            var kind = isServer ? "server" : (isQuery ? "query" : "channel")
            var title = isServer ? qsTr("Server") : (isQuery ? qsTr("Messages") : qsTr("Channels"))
            out.push({
                "target": target,
                "isServer": isServer,
                "isQuery": isQuery,
                "isChan": isChan,
                "sectionKind": kind,
                "sectionTitle": title,
                "sectionStart": kind !== previousKind,
                "sectionCount": kind === "channel" ? channelCount : (kind === "query" ? queryCount : 0)
            })
            previousKind = kind
        }
        return out
    }

    /// People panel model, derived from the channel's nick list: operators,
    /// voiced, then everyone else, each sorted alphabetically and filtered
    /// live by the panel's search field.
    readonly property var peopleEntries: {
        var filter = page.peopleFilter.trim().toLowerCase()
        var ops = []
        var voiced = []
        var others = []
        for (var i = 0; i < page.nickList.length; ++i) {
            var raw = String(page.nickList[i])
            var m = /^([@+%~&]?)(.*)$/.exec(raw)
            var prefix = m ? m[1] : ""
            var bare = m ? m[2] : raw
            if (bare.length === 0) {
                continue
            }
            if (filter.length > 0 && bare.toLowerCase().indexOf(filter) === -1) {
                continue
            }
            var entry = {"nick": raw, "bare": bare, "prefix": prefix, "group": ""}
            if (prefix === "@" || prefix === "%" || prefix === "~" || prefix === "&") {
                ops.push(entry)
            } else if (prefix === "+") {
                voiced.push(entry)
            } else {
                others.push(entry)
            }
        }
        function byBare(a, b) {
            var x = String(a.bare).toLowerCase()
            var y = String(b.bare).toLowerCase()
            return x < y ? -1 : (x > y ? 1 : 0)
        }
        ops.sort(byBare)
        voiced.sort(byBare)
        others.sort(byBare)
        function label(base, n) { return base + " (" + n + ")" }
        for (var o = 0; o < ops.length; ++o) { ops[o].group = label(qsTr("Operators"), ops.length) }
        for (var v = 0; v < voiced.length; ++v) { voiced[v].group = label(qsTr("Voiced"), voiced.length) }
        for (var r = 0; r < others.length; ++r) { others[r].group = label(qsTr("Others"), others.length) }
        return ops.concat(voiced, others)
    }

    // ---------------------------------------------------------------------- //
    // Layout
    // ---------------------------------------------------------------------- //
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- sidebar ---------------- //
        Rectangle {
            id: sidebar
            Layout.preferredWidth: page.sideWidth
            Layout.minimumWidth: Kirigami.Units.gridUnit * 9
            Layout.fillHeight: true
            color: page.sideBg

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

                ListView {
                    id: bufferList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    reuseItems: true
                    model: page.buffers
                    spacing: 0
                    cacheBuffer: Kirigami.Units.gridUnit * 20

                    // One delegate per buffer: the "*server*" console plus the
                    // joined channels and query windows. Section headers are
                    // part of the model, so a single flat list still renders
                    // as "Server" / "Messages" / "Channels".
                    delegate: Controls.ItemDelegate {
                        id: bufferDelegate
                        required property string target
                        required property bool isServer
                        required property bool isQuery
                        required property bool isChan
                        required property string sectionKind
                        required property string sectionTitle
                        required property bool sectionStart
                        required property int sectionCount

                        readonly property bool active: page.sameTarget(bufferDelegate.target, page.currentChannel)
                        readonly property bool hasUnread: !bufferDelegate.active && !bufferDelegate.isServer
                            && page.bridge !== null && page.bridge.unread_count > 0
                        // Tile colour for channels: the channel's own hash
                        // colour (same colour as that channel's nicks).
                        readonly property color tileColor: bufferDelegate.isServer
                            ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.14)
                            : ThemeEngine.nickColor(bufferDelegate.target, page.darkTheme)
                        // Queries show the nick initial; the presence dot is
                        // connection-based (the core exposes no per-nick
                        // presence): online while connected, offline otherwise.
                        readonly property color presenceColor: page.connected ? page.onlineC : page.offlineC

                        width: bufferList.width
                        hoverEnabled: true
                        padding: 0
                        // The close button, accent bar and tile must never
                        // paint outside this row's bounds.
                        clip: true

                        onClicked: page.openChannel(bufferDelegate.target)

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: bufferDelegate.isServer
                            ? qsTr("Server messages and notices")
                            : bufferDelegate.target

                        background: Item {
                            Rectangle {
                                id: rowPill
                                anchors.fill: parent
                                anchors.leftMargin: Kirigami.Units.smallSpacing
                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                anchors.topMargin: 1
                                anchors.bottomMargin: 1
                                radius: page.rowRad
                                color: bufferDelegate.active
                                    ? page.rowSel
                                    : (bufferDelegate.hovered ? page.rowHv : "transparent")
                                Behavior on color {
                                    ColorAnimation { duration: ThemeEngine.motionDuration }
                                }
                            }

                            // 3px accent bar overlaid on the selected pill's
                            // leading edge (inside the delegate): the
                            // selected row keeps every other row's margins.
                            Rectangle {
                                visible: bufferDelegate.active
                                anchors.left: rowPill.left
                                anchors.leftMargin: 2
                                anchors.top: rowPill.top
                                anchors.topMargin: Math.round(rowPill.height * 0.22)
                                anchors.bottom: rowPill.bottom
                                anchors.bottomMargin: Math.round(rowPill.height * 0.22)
                                implicitWidth: 3
                                radius: 1.5
                                color: page.accentC
                            }
                        }

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                visible: bufferDelegate.sectionStart
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                                Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                                Layout.topMargin: bufferDelegate.isServer ? 0 : Kirigami.Units.smallSpacing
                                Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
                                // The count and the join action sit in the
                                // same row, so they need real breathing room
                                // rather than a hairline gap.
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    Layout.fillWidth: true
                                    text: bufferDelegate.sectionTitle
                                    color: page.sectionTxt
                                    opacity: 0.8
                                    font.bold: true
                                    font.pointSize: page.sectionSz
                                    elide: Text.ElideRight
                                }

                                Controls.Label {
                                    visible: bufferDelegate.sectionCount > 0
                                    text: bufferDelegate.sectionCount
                                    color: page.mutedTxt
                                    font.pointSize: page.sectionSz
                                }

                                // Join action: lives in the Channels header
                                // row (next to the count), not beside any
                                // buffer's close control.
                                Controls.ToolButton {
                                    id: joinAddButton
                                    visible: bufferDelegate.sectionKind === "channel"
                                    display: Controls.AbstractButton.IconOnly
                                    // `icon.name` does not resolve in this
                                    // control's style (renders an empty box),
                                    // so draw the glyph directly.
                                    contentItem: Controls.Label {
                                        text: "+"
                                        color: Kirigami.Theme.textColor
                                        font.bold: true
                                        font.pointSize: Math.round(Kirigami.Theme.defaultFont.pointSize * 1.2)
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.25)
                                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.25)
                                    onClicked: page.openJoinDialog()

                                    // A bare glyph reads as decoration: give
                                    // it a resting surface so it is obviously
                                    // the join action.
                                    background: Rectangle {
                                        radius: page.rowRad
                                        color: joinAddButton.hovered || joinAddButton.activeFocus
                                               ? page.rowHv
                                               : ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.06)
                                        border.width: 1
                                        border.color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
                                        Behavior on color {
                                            ColorAnimation { duration: ThemeEngine.motionDuration }
                                        }
                                    }

                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.text: qsTr("Join a channel (Ctrl+J)")
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: page.rowHt
                                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                                Layout.rightMargin: Kirigami.Units.smallSpacing * 2

                                RowLayout {
                                    id: bufferRowInner
                                    anchors.fill: parent
                                    // Right padding reserves the close
                                    // control's slot INSIDE the row, so it
                                    // never overlaps the label or paints
                                    // outside the pill.
                                    anchors.rightMargin: Math.round(Kirigami.Units.gridUnit * 1.25) + Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    // Leading element per row kind: a server
                                    // glyph for the console, a rounded "#"
                                    // tile for channels, the nick initial
                                    // for queries.
                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.2)
                                        Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.2)
                                        radius: bufferDelegate.isQuery ? width / 2 : page.rowRad
                                        color: bufferDelegate.tileColor

                                        Kirigami.Icon {
                                            anchors.centerIn: parent
                                            visible: bufferDelegate.isServer
                                            source: "network-server"
                                            color: Kirigami.Theme.textColor
                                            implicitWidth: Math.round(parent.width * 0.66)
                                            implicitHeight: implicitWidth
                                        }

                                        Controls.Label {
                                            anchors.centerIn: parent
                                            visible: !bufferDelegate.isServer
                                            text: bufferDelegate.isQuery
                                                  ? ThemeEngine.initial(bufferDelegate.target)
                                                  : "#"
                                            color: ThemeEngine.contrastingTextColor(bufferDelegate.tileColor)
                                            font.bold: true
                                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize)
                                        }

                                        // Presence dot for query windows
                                        // (see presenceColor above).
                                        Rectangle {
                                            visible: bufferDelegate.isQuery
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            anchors.rightMargin: -1
                                            anchors.bottomMargin: -1
                                            implicitWidth: Math.round(parent.width * 0.38)
                                            implicitHeight: implicitWidth
                                            radius: width / 2
                                            color: bufferDelegate.presenceColor
                                            border.width: 1
                                            border.color: page.sideBg
                                        }
                                    }

                                    Controls.Label {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        text: bufferDelegate.isServer
                                              ? page.serverBufferLabel
                                              : (bufferDelegate.isQuery
                                                 ? bufferDelegate.target
                                                 : bufferDelegate.target.substring(1))
                                        color: Kirigami.Theme.textColor
                                        font.bold: bufferDelegate.active || bufferDelegate.hasUnread
                                        elide: Text.ElideRight
                                    }

                                    // Per-row unread dot (the core only
                                    // tracks a global counter, so every
                                    // non-visible buffer carries the dot
                                    // while it is non-zero).
                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: bufferDelegate.hasUnread
                                        implicitWidth: 8
                                        implicitHeight: 8
                                        radius: width / 2
                                        color: page.unreadBg

                                        Controls.ToolTip.visible: unreadHover.hovered
                                        Controls.ToolTip.text: page.bridge !== null
                                            ? qsTr("%n unread message(s)", "", page.bridge.unread_count) : ""

                                        HoverHandler {
                                            id: unreadHover
                                        }
                                    }
                                }

                                // The close control is OVERLAID top-right
                                // inside the row (slot always reserved via
                                // the inner row's right margin): it only
                                // fades in on hover or keyboard focus, so it
                                // can never shove the log, float outside the
                                // pill, or sit beside the Channels "+" (which
                                // now lives in the section header).
                                Controls.ToolButton {
                                    id: closeButton
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !bufferDelegate.isServer
                                    opacity: (bufferDelegate.hovered || bufferDelegate.active
                                              || closeButton.activeFocus || bufferDelegate.activeFocus) ? 1 : 0
                                    // An invisible control must not swallow
                                    // clicks meant for opening the buffer.
                                    enabled: closeButton.opacity > 0
                                    icon.name: "window-close"
                                    display: Controls.AbstractButton.IconOnly
                                    implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.25)
                                    implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.25)
                                    onClicked: page.closeBuffer(bufferDelegate.target)

                                    Behavior on opacity {
                                        NumberAnimation { duration: ThemeEngine.motionDuration }
                                    }

                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.text: bufferDelegate.isQuery
                                                          ? qsTr("Close conversation")
                                                          : qsTr("Leave channel")
                                }
                            }

                            TapHandler {
                                acceptedButtons: Qt.MiddleButton
                                onTapped: {
                                    if (!bufferDelegate.isServer) {
                                        page.closeBuffer(bufferDelegate.target)
                                    }
                                }
                            }
                        }
                    }

                    Controls.ScrollBar.vertical: Controls.ScrollBar {
                        id: channelScroll
                        policy: Controls.ScrollBar.AsNeeded
                        contentItem: Rectangle {
                            implicitWidth: 6
                            radius: width / 2
                            color: ThemeEngine.withAlpha(Kirigami.Theme.textColor,
                                                         channelScroll.pressed ? 0.45 : 0.22)
                            opacity: channelScroll.active ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: page.hairline
        }

        // ---------------- message view ---------------- //
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: page.joinError.length > 0
                text: page.joinError
                type: Kirigami.MessageType.Error
                showCloseButton: true
                onVisibleChanged: if (!visible) page.joinError = ""
            }

            // Topic bar: a real surface (not bare text floating over the log)
            // carrying the channel tile + name + one-line topic (click to
            // expand), with the people-panel toggle docked into its right end
            // so it reads as part of the bar, not an unanchored square on the
            // panel boundary.
            Rectangle {
                id: topicBar
                visible: page.isChannel(page.currentChannel)
                Layout.fillWidth: true
                implicitHeight: topicLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
                color: page.panelBg

                HoverHandler {
                    id: topicHover
                }

                Controls.ToolTip.visible: topicHover.hovered && !page.topicExpanded && page.currentTopic.length > 0
                Controls.ToolTip.text: page.currentTopic

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 1
                    color: page.hairline
                }

                // Click-to-expand for the text zone. Declared before the row
                // so the toggle stays on top and keeps its own clicks.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.topicExpanded = !page.topicExpanded
                }

                RowLayout {
                    id: topicLayout
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    // Channel tile: the channel's own hash colour, same as its
                    // sidebar row and the window header glyph.
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.1)
                        implicitHeight: implicitWidth
                        radius: page.rowRad
                        color: ThemeEngine.nickColor(page.currentChannel, page.darkTheme)

                        Controls.Label {
                            anchors.centerIn: parent
                            text: "#"
                            color: ThemeEngine.contrastingTextColor(parent.color)
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize)
                        }
                    }

                    Controls.Label {
                        id: topicName
                        Layout.alignment: Qt.AlignVCenter
                        Layout.maximumWidth: Math.round(topicBar.width * 0.45)
                        text: page.currentChannel
                        color: Kirigami.Theme.textColor
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    // Topic: one elided line by default; word-wrapped while
                    // expanded, capped at a few lines so a pathological topic
                    // can never squeeze the log/composer out of the window.
                    Controls.Label {
                        id: topicLabel
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        textFormat: Text.PlainText
                        text: page.currentTopic.length > 0 ? page.currentTopic : qsTr("No topic set")
                        font.italic: page.currentTopic.length === 0
                        maximumLineCount: page.topicExpanded ? 6 : 1
                        elide: Text.ElideRight
                        wrapMode: page.topicExpanded ? Text.WordWrap : Text.NoWrap
                        color: page.currentTopic.length > 0 ? Kirigami.Theme.textColor : page.mutedTxt
                        font.pointSize: page.eventSz
                    }

                    // People-panel toggle, docked in the bar's right end with
                    // a resting surface of its own (checked = the panel is
                    // shown).  The glyph is drawn with Kirigami.Icon so it
                    // follows the theme colours like the rest of the page.
                    Controls.ToolButton {
                        id: peopleToggle
                        Layout.alignment: Qt.AlignVCenter
                        display: Controls.AbstractButton.IconOnly
                        checkable: true
                        checked: page.peopleVisible
                        onToggled: page.peopleVisible = checked
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.35)
                        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.35)

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: checked ? qsTr("Hide people panel") : qsTr("Show people panel")

                        background: Rectangle {
                            radius: page.rowRad
                            color: peopleToggle.checked
                                ? page.rowSel
                                : (peopleToggle.hovered || peopleToggle.activeFocus
                                   ? page.rowHv
                                   : ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.06))
                            border.width: 1
                            border.color: peopleToggle.checked
                                ? page.accentC
                                : ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: Item {
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                source: "system-users"
                                color: Kirigami.Theme.textColor
                                width: Math.round(Kirigami.Units.gridUnit * 0.9)
                                height: width
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.hairline
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: messageView
                    anchors.fill: parent
                    clip: true
                    model: msgModel
                    reuseItems: true
                    cacheBuffer: Kirigami.Units.gridUnit * 40
                    spacing: 0
                    topMargin: Kirigami.Units.smallSpacing
                    bottomMargin: Kirigami.Units.smallSpacing
                    // Keep self-message avatars out of the overlay scrollbar gutter.
                    rightMargin: Kirigami.Units.smallSpacing * 2

                    onAtYEndChanged: {
                        if (atYEnd) {
                            page.hasUnseenBelow = false
                        }
                    }

                    // TODO(code-highlight): fenced code blocks are rendered as
                    // plain text — wiring KSyntaxHighlighting needs a C++ bridge.
                    // The delegate picks up nick/text/timestamp/isSelf/isHighlight
                    // straight from the model roles (see MessageDelegate).
                    delegate: MessageDelegate { }

                    // Fade the log in when the user switches channel.
                    NumberAnimation {
                        id: contentFade
                        target: messageView
                        property: "opacity"
                        from: 0
                        to: 1
                        duration: Math.max(60, ThemeEngine.motionDuration * 2)
                        easing.type: Easing.OutCubic
                    }

                    Controls.ScrollBar.vertical: Controls.ScrollBar {
                        id: messageScroll
                        policy: Controls.ScrollBar.AsNeeded
                        contentItem: Rectangle {
                            implicitWidth: 6
                            radius: width / 2
                            color: ThemeEngine.withAlpha(Kirigami.Theme.textColor,
                                                         messageScroll.pressed ? 0.45 : 0.22)
                            opacity: messageScroll.active ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }
                    }

                    // ---------------- empty state ---------------- //
                    ColumnLayout {
                        anchors.centerIn: parent
                        anchors.margins: Kirigami.Units.largeSpacing
                        width: Math.min(parent.width - Kirigami.Units.largeSpacing * 2, Kirigami.Units.gridUnit * 20)
                        visible: messageView.count === 0
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.alignment: Qt.AlignHCenter
                            source: !page.connected ? "network-offline"
                                                    : (page.currentChannel === "*server*" ? "utilities-terminal" : "dialog-messages")
                            color: Kirigami.Theme.disabledTextColor
                            implicitWidth: Kirigami.Units.iconSizes.huge
                            implicitHeight: Kirigami.Units.iconSizes.huge
                            opacity: 0.7
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: {
                                if (!page.connected) {
                                    return qsTr("Not connected")
                                }
                                if (page.currentChannel === "*server*") {
                                    return qsTr("Server console")
                                }
                                if (!page.isChannel(page.currentChannel)) {
                                    return qsTr("No messages yet")
                                }
                                return qsTr("No messages in %1 yet").arg(page.currentChannel)
                            }
                            color: Kirigami.Theme.textColor
                            font.bold: true
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            text: {
                                if (!page.connected) {
                                    return qsTr("Connect to a server to start chatting.")
                                }
                                if (page.currentChannel === "*server*") {
                                    return qsTr("Server notices, joins and parts show up here.")
                                }
                                if (!page.isChannel(page.currentChannel)) {
                                    return qsTr("Private messages with this nick show up here.")
                                }
                                return qsTr("Say hi!")
                            }
                            color: Kirigami.Theme.disabledTextColor
                        }
                    }
                }

                // Floating pill: traffic arrived while scrolled up.
                Controls.Button {
                    id: newMessagesPill
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Kirigami.Units.smallSpacing * 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: page.hasUnseenBelow
                    z: 2
                    leftPadding: Kirigami.Units.smallSpacing * 2
                    rightPadding: Kirigami.Units.smallSpacing * 2
                    icon.name: "go-down"
                    text: qsTr("New messages")
                    onClicked: {
                        page.hasUnseenBelow = false
                        page.scrollToEnd()
                    }

                    background: Rectangle {
                        radius: height / 2
                        color: newMessagesPill.pressed
                            ? Qt.darker(page.accentC, 1.2)
                            : page.accentC
                        Behavior on color {
                            ColorAnimation { duration: ThemeEngine.motionDuration }
                        }
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.alignment: Qt.AlignVCenter
                            source: newMessagesPill.icon.name
                            color: page.accentTxt
                            implicitWidth: Math.round(Kirigami.Units.gridUnit * 0.8)
                            implicitHeight: implicitWidth
                        }

                        Controls.Label {
                            Layout.alignment: Qt.AlignVCenter
                            text: newMessagesPill.text
                            color: page.accentTxt
                            font.bold: true
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        }
                    }
                }
            }

            // ---------------- input ---------------- //
            // The composer is the last row of the message column: the log
            // above it is Layout.fillHeight, so the list absorbs every resize
            // and this bar keeps its implicit height (the "New messages" pill
            // lives inside the log, so it can never push anything out either).
            // The extra bottom inset keeps the input frame visibly clear of
            // the window's bottom edge instead of running into it.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: inputColumn.implicitHeight + Kirigami.Units.smallSpacing * 3
                color: Kirigami.Theme.backgroundColor

                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: page.hairline
                }

                FontMetrics {
                    id: inputMetrics
                    font: messageInput.font
                }

                ColumnLayout {
                    id: inputColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    anchors.bottomMargin: Kirigami.Units.smallSpacing * 2
                    spacing: Kirigami.Units.smallSpacing / 2

                    // The server console only takes slash commands — say so
                    // inline instead of failing silently.
                    Controls.Label {
                        visible: page.currentChannel === "*server*"
                        Layout.fillWidth: true
                        text: qsTr("Server console — slash commands only, e.g. /join #channel")
                        color: page.mutedTxt
                        font.pointSize: page.eventSz
                        elide: Text.ElideRight
                    }

                    RowLayout {
                        id: inputRow
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            id: inputFrame
                            readonly property int pad: Math.round(Kirigami.Units.smallSpacing * 1.5)
                            readonly property int maxFieldHeight: Math.round(inputMetrics.lineSpacing * 5)

                            Layout.fillWidth: true
                            implicitHeight: Math.min(inputFrame.maxFieldHeight, messageInput.implicitHeight) + inputFrame.pad * 2
                            radius: page.inputRad
                            color: Kirigami.Theme.alternateBackgroundColor
                            border.width: 1
                            border.color: messageInput.activeFocus ? page.accentC : page.hairline
                            Behavior on border.color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }

                            Controls.TextArea {
                                id: messageInput
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: inputFrame.pad
                                height: Math.min(inputFrame.maxFieldHeight, implicitHeight)

                                background: null
                                leftPadding: inputFrame.pad
                                rightPadding: inputFrame.pad
                                topPadding: 0
                                bottomPadding: 0

                                enabled: page.connected
                                placeholderText: {
                                    if (!page.connected) {
                                        return qsTr("Connect to a server to send messages")
                                    }
                                    if (page.currentChannel === "*server*") {
                                        return qsTr("Type a command, e.g. /join #channel")
                                    }
                                    return qsTr("Message %1").arg(page.currentChannel)
                                }
                                wrapMode: Controls.TextArea.Wrap
                                selectByMouse: true

                                // Enter sends, Shift+Enter inserts a newline. Tab
                                // completes nicks in the current channel.
                                Keys.onPressed: (event) => {
                                    if (event.key === Qt.Key_Tab) {
                                        event.accepted = true
                                        page.tabComplete()
                                        return
                                    }
                                    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) {
                                        return
                                    }
                                    if (event.modifiers & Qt.ShiftModifier) {
                                        event.accepted = false
                                        return
                                    }
                                    event.accepted = true
                                    page.sendCurrent()
                                }
                            }
                        }

                        Controls.Button {
                            id: sendButton
                            Layout.alignment: Qt.AlignBottom
                            Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.9)
                            Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.9)
                            enabled: page.connected && page.currentChannel !== "*server*" && messageInput.text.trim().length > 0
                            onClicked: page.sendCurrent()

                            Controls.ToolTip.visible: hovered
                            Controls.ToolTip.text: qsTr("Send message")

                            background: Rectangle {
                                radius: width / 2
                                color: !sendButton.enabled
                                    ? "transparent"
                                    : (sendButton.pressed
                                       ? Qt.darker(page.accentC, 1.2)
                                       : page.accentC)
                                border.width: 1
                                border.color: sendButton.enabled
                                    ? "transparent"
                                    : ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.5)
                                Behavior on color {
                                    ColorAnimation { duration: ThemeEngine.motionDuration }
                                }
                            }

                            contentItem: Item {
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    source: "document-send"
                                    // No extra alpha on top of the style's own
                                    // disabled dimming.
                                    color: sendButton.enabled
                                        ? page.accentTxt
                                        : Kirigami.Theme.disabledTextColor
                                    width: Math.round(Kirigami.Units.gridUnit * 0.95)
                                    height: width
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---------------- people panel ---------------- //
        Rectangle {
            // Auto-hide on a narrow window: with a 250px sidebar plus this
            // panel there is not enough room left for the log to stay
            // readable, and squeezing it pushed the panel past the window
            // edge.  The topic-bar toggle still works whenever it is shown.
            visible: page.isChannel(page.currentChannel) && page.peopleVisible
                     && (page.width - page.sideWidth) >= page.peoplePanelMinSpace
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.minimumWidth: Kirigami.Units.gridUnit * 8
            Layout.fillHeight: true
            color: page.panelBg

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Controls.Label {
                    text: qsTr("People (%1)").arg(page.peopleEntries.length)
                    font.bold: true
                    color: page.sectionTxt
                    font.pointSize: page.sectionSz
                    leftPadding: Kirigami.Units.smallSpacing * 2
                    topPadding: Kirigami.Units.smallSpacing
                    bottomPadding: Kirigami.Units.smallSpacing / 2
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                    Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    implicitHeight: peopleFilterField.implicitHeight + Kirigami.Units.smallSpacing
                    radius: page.inputRad
                    color: Kirigami.Theme.backgroundColor
                    border.width: 1
                    border.color: peopleFilterField.activeFocus ? page.accentC : page.hairline
                    Behavior on border.color {
                        ColorAnimation { duration: ThemeEngine.motionDuration }
                    }

                    Controls.TextField {
                        id: peopleFilterField
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing / 2
                        leftPadding: Kirigami.Units.smallSpacing
                        rightPadding: Kirigami.Units.smallSpacing
                        background: null
                        placeholderText: qsTr("Filter…")
                        onTextChanged: page.peopleFilter = text
                    }
                }

                ListView {
                    id: peopleList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: page.peopleEntries
                    reuseItems: true
                    section.property: "group"
                    section.delegate: Controls.Label {
                        required property string section
                        width: peopleList.width
                        text: section
                        color: page.mutedTxt
                        font.bold: true
                        font.pointSize: page.eventSz
                        leftPadding: Kirigami.Units.smallSpacing * 2
                        topPadding: Kirigami.Units.smallSpacing
                        bottomPadding: Kirigami.Units.smallSpacing / 2
                        elide: Text.ElideRight
                    }

                    delegate: Controls.ItemDelegate {
                        id: personDelegate
                        required property string nick
                        required property string bare
                        required property string prefix

                        // Presence follows rank: operators read as online,
                        // voiced as away, everyone else as offline.
                        readonly property color presenceColor: personDelegate.prefix === "+"
                            ? page.awayC
                            : ((personDelegate.prefix.length > 0) ? page.onlineC : page.offlineC)
                        readonly property color avatarColor: ThemeEngine.nickColor(personDelegate.bare, page.darkTheme)

                        width: peopleList.width
                        hoverEnabled: true
                        padding: 0
                        clip: true

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: personDelegate.nick

                        background: Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: page.rowRad
                            color: personDelegate.hovered ? page.rowHv : "transparent"
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.leftMargin: Kirigami.Units.smallSpacing
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.1)
                                Layout.preferredHeight: Layout.preferredWidth
                                radius: width / 2
                                color: personDelegate.avatarColor

                                Controls.Label {
                                    anchors.centerIn: parent
                                    text: ThemeEngine.initial(personDelegate.bare)
                                    color: ThemeEngine.contrastingTextColor(personDelegate.avatarColor)
                                    font.bold: true
                                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 2)
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.rightMargin: -1
                                    anchors.bottomMargin: -1
                                    implicitWidth: Math.round(parent.width * 0.36)
                                    implicitHeight: implicitWidth
                                    radius: width / 2
                                    color: personDelegate.presenceColor
                                    border.width: 1
                                    border.color: page.panelBg
                                }
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredHeight: page.rowHt
                                verticalAlignment: Text.AlignVCenter
                                text: personDelegate.bare
                                elide: Text.ElideRight
                                color: Kirigami.Theme.textColor
                            }

                            // Rank badge column: every row reserves the same
                            // fixed-width slot, so the badges line up in one
                            // right-hand column (and nicks truncate at the
                            // same edge whether or not the row has a badge).
                            // The glyph is a styled Label showing the ASCII
                            // mode prefix (@ / + / % / ~ / &) — text, so it
                            // always renders, never a missing icon.
                            Item {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.rightMargin: Kirigami.Units.smallSpacing
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.15)
                                Layout.preferredHeight: page.rowHt

                                Rectangle {
                                    anchors.centerIn: parent
                                    visible: personDelegate.prefix.length > 0
                                    implicitWidth: Math.round(Kirigami.Units.gridUnit)
                                    implicitHeight: implicitWidth
                                    radius: height / 3
                                    color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.10)

                                    Controls.Label {
                                        anchors.centerIn: parent
                                        text: personDelegate.prefix
                                        color: page.mutedTxt
                                        font.bold: true
                                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 2)
                                    }
                                }
                            }
                        }

                        onClicked: {
                            var nick = personDelegate.bare
                            if (nick.length === 0) {
                                return
                            }
                            page.addBuffer(nick)
                            page.openChannel(nick)
                        }
                    }
                }
            }
        }
    }

    // Ctrl+J opens the join dialog from anywhere on this page.
    Shortcut {
        sequence: "Ctrl+J"
        context: Qt.ApplicationShortcut
        onActivated: page.openJoinDialog()
    }

    // Join dialog: replaces the old bottom text field. Accepts #, &, +, !
    // or a bare name (only bare names gain a "#"), plus an optional key.
    Controls.Dialog {
        id: joinDialog
        title: qsTr("Join channel")
        modal: true
        parent: Controls.Overlay.overlay
        anchors.centerIn: parent
        standardButtons: Controls.Dialog.Ok | Controls.Dialog.Cancel
        onOpened: {
            joinNameField.text = ""
            joinKeyField.text = ""
            joinAutojoinBox.checked = false
            joinDialog.standardButton(Controls.Dialog.Ok).enabled = false
            joinNameField.forceActiveFocus()
        }
        onAccepted: page.submitJoinDialog()

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                Layout.fillWidth: true
                text: qsTr("Channel name (a bare name becomes #name):")
                color: Kirigami.Theme.textColor
                wrapMode: Text.WordWrap
            }

            Controls.TextField {
                id: joinNameField
                Layout.fillWidth: true
                Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                placeholderText: qsTr("#channel")
                onTextChanged: joinDialog.standardButton(Controls.Dialog.Ok).enabled = text.trim().length > 0
                onAccepted: {
                    if (text.trim().length > 0) {
                        joinDialog.accept()
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                text: qsTr("Channel key (only for locked channels):")
                color: Kirigami.Theme.textColor
                wrapMode: Text.WordWrap
            }

            Controls.TextField {
                id: joinKeyField
                Layout.fillWidth: true
                placeholderText: qsTr("Optional")
                echoMode: Controls.TextField.Password
                onAccepted: {
                    if (joinNameField.text.trim().length > 0) {
                        joinDialog.accept()
                    }
                }
            }

            Controls.CheckBox {
                id: joinAutojoinBox
                Layout.fillWidth: true
                text: qsTr("Join on connect")
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // Actions
    // ---------------------------------------------------------------------- //
    function openChannel(target)
    {
        if (target === undefined || target === null || target.length === 0) {
            return
        }
        var switching = !page.sameTarget(target, page.currentChannel)
        page.currentChannel = page.existingTarget(target)
        if (page.bridge !== null && typeof page.bridge.mark_read === "function") {
            page.bridge.mark_read()
        }
        if (page.hostWindow !== null && page.hostWindow !== undefined) {
            page.hostWindow.chatChannel = page.currentChannel
        }
        page.joinError = ""
        page.hasUnseenBelow = false
        page.topicExpanded = false
        page.refreshHistory()
        if (page.bridge !== null) {
            page.currentTopic = (typeof page.bridge.topic_for === "function")
                ? page.bridge.topic_for(target) : ""
            var nicks = (typeof page.bridge.nicks_for === "function")
                ? page.bridge.nicks_for(target) : ""
            page.nickList = nicks.length === 0 ? [] : nicks.split(" ")
        }
        if (switching) {
            contentFade.restart()
        }
    }

    /// True for channel targets: the # & + ! prefixes. Everything else is a
    /// query nick or the *server* console.
    function isChannel(target)
    {
        if (target === undefined || target === null || target === "*server*") {
            return false
        }
        var c = String(target).charAt(0)
        return c === "#" || c === "&" || c === "+" || c === "!"
    }

    function sameTarget(a, b)
    {
        return String(a).toLowerCase() === String(b).toLowerCase()
    }

    function existingTarget(target)
    {
        for (var i = 0; i < page.channels.length; ++i) {
            if (page.sameTarget(page.channels[i], target)) {
                return page.channels[i]
            }
        }
        return target
    }

    function foldDuplicateBuffers()
    {
        var seen = {}
        var out = []
        for (var i = 0; i < page.channels.length; ++i) {
            var key = String(page.channels[i]).toLowerCase()
            if (seen[key]) {
                continue
            }
            seen[key] = true
            out.push(page.channels[i])
        }
        if (out.length !== page.channels.length) {
            page.channels = out
            page.currentChannel = page.existingTarget(page.currentChannel)
            if (page.hostWindow !== null) {
                page.hostWindow.chatChannel = page.currentChannel
            }
        }
    }

    function addBuffer(target)
    {
        if (target === undefined || target === null || target.length === 0) {
            return
        }
        var have = page.existingTarget(target)
        if (page.channels.indexOf(have) !== -1) {
            page.foldDuplicateBuffers()
            return
        }
        var list = page.channels.slice()
        list.push(target)
        page.channels = list
    }

    function removeBuffer(target)
    {
        var list = page.channels.filter(function (c) { return !page.sameTarget(c, target) })
        if (list.length === 0) {
            list = ["*server*"]
        }
        page.channels = list
    }

    function closeBuffer(target)
    {
        if (target === undefined || target === null || target === "*server*") {
            return
        }
        if (page.isChannel(target) && page.bridge !== null
                && typeof page.bridge.part_channel === "function") {
            page.bridge.part_channel(target)
        }
        var leaving = page.sameTarget(page.currentChannel, target)
        page.removeBuffer(target)
        if (leaving) {
            page.openChannel("*server*")
        }
    }

    function refreshHistory()
    {
        msgModel.load_channel(page.currentChannel)
        page.scrollToEnd()
    }

    function scrollIfAtBottom()
    {
        // Conditional autoscroll for live traffic: stay pinned when already at
        // the bottom, but never yank a user who scrolled up to read back.
        if (messageView.atYEnd) {
            page.scrollToEnd()
        }
    }

    function scrollToEnd()
    {
        messageView.positionViewAtEnd()
    }

    function sendCurrent()
    {
        var body = messageInput.text.trim()
        if (body.length === 0 || page.bridge === null) {
            return
        }
        if (body.charAt(0) === "/") {
            if (page.runSlash(body)) {
                messageInput.text = ""
                messageInput.forceActiveFocus()
            }
            return
        }
        if (page.currentChannel === "*server*") {
            return
        }
        page.bridge.send_message(page.currentChannel, body)
        messageInput.text = ""
        messageInput.forceActiveFocus()
    }

    function runSlash(body)
    {
        var space = body.indexOf(" ")
        var cmd = (space < 0 ? body : body.substring(0, space)).toLowerCase()
        var rest = space < 0 ? "" : body.substring(space + 1).trim()
        if (cmd === "/join") {
            var bits = rest.split(/\s+/).filter(function (w) { return w.length > 0 })
            if (bits.length === 0) {
                return false
            }
            page.joinChannel(bits[0], bits.length > 1 ? bits.slice(1).join(" ") : "")
            return true
        }
        if (cmd === "/part" || cmd === "/close" || cmd === "/wc") {
            if (page.bridge === null) {
                return true
            }
            var words = rest.length > 0 ? rest.split(" ") : []
            var chan = words.length > 0 && words[0].length > 0 ? words[0] : page.currentChannel
            var reason = words.length > 1 ? words.slice(1).join(" ").trim() : ""
            if (!page.isChannel(chan)) {
                page.closeBuffer(chan)
                return true
            }
            if (reason.length > 0) {
                page.bridge.send_raw("PART " + chan + " :" + reason)
            } else if (typeof page.bridge.part_channel === "function") {
                page.bridge.part_channel(chan)
            } else {
                page.bridge.send_raw("PART " + chan)
            }
            return true
        }
        if (cmd === "/query" || cmd === "/msg") {
            var qbits = rest.split(" ")
            var nick = qbits[0]
            if (!nick) {
                return false
            }
            page.addBuffer(nick)
            page.openChannel(nick)
            if (cmd === "/msg" && qbits.length > 1) {
                page.bridge.send_message(nick, qbits.slice(1).join(" "))
            }
            return true
        }
        if (cmd === "/me") {
            if (page.currentChannel === "*server*" || rest.length === 0) {
                return false
            }
            page.bridge.send_message(page.currentChannel, "\u0001ACTION " + rest + "\u0001")
            return true
        }
        if (cmd === "/nick") {
            if (rest.length === 0) {
                return false
            }
            page.bridge.send_raw("NICK " + rest.split(" ")[0])
            return true
        }
        if (cmd === "/whois") {
            var who = rest.length > 0 ? rest.split(" ")[0] : page.currentChannel
            if (page.isChannel(who) || who === "*server*") {
                return false
            }
            page.addBuffer(who)
            page.openChannel(who)
            page.bridge.send_raw("WHOIS " + who)
            return true
        }
        if (cmd === "/notice") {
            var nbits = rest.split(" ")
            if (nbits.length < 2) {
                return false
            }
            page.bridge.send_raw("NOTICE " + nbits[0] + " :" + nbits.slice(1).join(" "))
            return true
        }
        if (cmd === "/away") {
            page.bridge.send_raw(rest.length > 0 ? ("AWAY :" + rest) : "AWAY")
            return true
        }
        if (cmd === "/back") {
            page.bridge.send_raw("AWAY")
            return true
        }
        if (cmd === "/topic") {
            if (!page.isChannel(page.currentChannel)) {
                return false
            }
            if (rest.length === 0) {
                page.bridge.send_raw("TOPIC " + page.currentChannel)
            } else {
                page.bridge.send_raw("TOPIC " + page.currentChannel + " :" + rest)
            }
            return true
        }
        if (cmd === "/invite") {
            var inv = rest.split(" ")
            if (inv.length === 0 || inv[0].length === 0) {
                return false
            }
            var ichan = inv.length > 1 ? inv[1] : page.currentChannel
            page.bridge.send_raw("INVITE " + inv[0] + " " + ichan)
            return true
        }
        if (cmd === "/kick") {
            var kb = rest.split(" ")
            if (kb.length === 0 || !page.isChannel(page.currentChannel)) {
                return false
            }
            var kreason = kb.length > 1 ? kb.slice(1).join(" ") : ""
            page.bridge.send_raw("KICK " + page.currentChannel + " " + kb[0] + (kreason ? (" :" + kreason) : ""))
            return true
        }
        if (cmd === "/mode") {
            if (rest.length === 0) {
                return false
            }
            page.bridge.send_raw("MODE " + rest)
            return true
        }
        if (cmd === "/ctcp") {
            var cb = rest.split(" ")
            if (cb.length < 2) {
                return false
            }
            page.bridge.send_message(cb[0], "\u0001" + cb.slice(1).join(" ").toUpperCase() + "\u0001")
            return true
        }
        if (cmd === "/clear") {
            if (typeof page.bridge.clear_buffer === "function") {
                page.bridge.clear_buffer(page.currentChannel)
            }
            page.refreshHistory()
            return true
        }
        if (cmd === "/quit") {
            if (page.hostWindow !== null) {
                page.hostWindow.userDisconnect = true
            }
            page.bridge.disconnect_server()
            return true
        }
        if (cmd === "/raw" || cmd === "/quote") {
            if (rest.length === 0) {
                return false
            }
            page.bridge.send_raw(rest)
            return true
        }
        return false
    }

    function isNickServ(nick)
    {
        return page.sameTarget(nick, "NickServ")
    }

    function nickservAccount()
    {
        var cfg = (page.hostWindow !== null) ? page.hostWindow.appConfig : null
        if (cfg === null) {
            return ""
        }
        var account = String(cfg.nickservNick).trim()
        if (account.length === 0 || account.toLowerCase() === "nickserv") {
            account = String(cfg.nickname).trim()
        }
        return account.split(/\s+/)[0]
    }

    function isIdentifySuccess(text)
    {
        var t = String(text).toLowerCase()
        return t.indexOf("you are now logged in") !== -1
            || t.indexOf("you are now identified") !== -1
            || t.indexOf("already logged in") !== -1
            || t.indexOf("already identified") !== -1
            || t.indexOf("authentication successful") !== -1
            || t.indexOf("password accepted") !== -1
            || t.indexOf("you are now recognized") !== -1
    }

    function rememberPendingJoin(channel)
    {
        var ch = String(channel)
        if (ch.length === 0 || !page.isChannel(ch)) {
            return
        }
        for (var i = 0; i < page.pendingJoins.length; ++i) {
            if (page.sameTarget(page.pendingJoins[i], ch)) {
                return
            }
        }
        page.pendingJoins = page.pendingJoins.concat([ch])
    }

    function forgetPendingJoin(channel)
    {
        var out = []
        for (var i = 0; i < page.pendingJoins.length; ++i) {
            if (!page.sameTarget(page.pendingJoins[i], channel)) {
                out.push(page.pendingJoins[i])
            }
        }
        page.pendingJoins = out
    }

    /// Reclaim the registered nick after NickServ confirms the IDENTIFY
    /// (typically a 433 forced us onto a fallback nick while a ghost session
    /// still holds the account).  Once per connection: GHOST the stale session
    /// for our own account, then take the nick back.  The password never
    /// appears in the UI — IDENTIFY/GHOST lines are NickServ traffic the core
    /// already filters from display.
    function maybeGhost()
    {
        if (page.ghostDone || page.bridge === null || page.bridge === undefined) {
            return
        }
        page.ghostDone = true
        var cfg = (page.hostWindow !== null) ? page.hostWindow.appConfig : null
        if (cfg === null || cfg.nickservPassword.length === 0) {
            return
        }
        var account = page.nickservAccount()
        if (account.length === 0) {
            return
        }
        var current = String(page.bridge.nickname)
        if (current.length > 0 && current.toLowerCase() === account.toLowerCase()) {
            return
        }
        page.bridge.send_raw("PRIVMSG NickServ :GHOST " + account + " " + cfg.nickservPassword)
        page.bridge.send_raw("NICK " + account)
    }

    function startIdentifyAndJoin()
    {
        if (page.bridge === null) {
            return
        }
        var cfg = (page.hostWindow !== null) ? page.hostWindow.appConfig : null
        if (cfg !== null && cfg.identifyOnConnect && cfg.nickservPassword.length > 0) {
            var account = page.nickservAccount()
            if (account.length === 0) {
                page.applyAutojoin()
                return
            }
            page.bridge.send_raw("PRIVMSG NickServ :IDENTIFY " + account + " " + cfg.nickservPassword)
            identifyTimer.restart()
            return
        }
        page.applyAutojoin()
    }

    function applyAutojoin()
    {
        if (page.bridge === null) {
            return
        }
        var seen = {}
        var targets = []
        function add(ch) {
            var key = String(ch).toLowerCase()
            if (seen[key]) {
                return
            }
            seen[key] = true
            targets.push(ch)
        }
        if (!page.autojoinDone && page.hostWindow !== null && page.hostWindow.appConfig !== null) {
            var raw = page.hostWindow.appConfig.autojoin
            if (raw && raw.length > 0) {
                var parts = raw.split(/[\s,]+/)
                for (var i = 0; i < parts.length; ++i) {
                    var ch = parts[i].trim()
                    if (ch.length === 0) {
                        continue
                    }
                    if (!page.isChannel(ch)) {
                        ch = "#" + ch
                    }
                    add(ch)
                }
            }
        }
        page.autojoinDone = true
        for (var j = 0; j < page.pendingJoins.length; ++j) {
            add(page.pendingJoins[j])
        }
        for (var k = 0; k < targets.length; ++k) {
            page.bridge.join_channel(targets[k])
        }
    }

    property string tabPrefix: ""
    property var tabMatches: []
    property int tabIndex: 0

    function tabComplete()
    {
        var text = messageInput.text
        var pos = messageInput.cursorPosition
        var start = pos
        while (start > 0) {
            var ch = text.charAt(start - 1)
            if (ch === " " || ch === "\n") {
                break
            }
            start -= 1
        }
        var prefix = text.substring(start, pos)
        if (prefix.length === 0) {
            return
        }
        if (prefix !== page.tabPrefix) {
            page.tabPrefix = prefix
            page.tabIndex = 0
            var lower = prefix.toLowerCase()
            var out = []
            for (var i = 0; i < page.nickList.length; ++i) {
                var n = String(page.nickList[i]).replace(/^[@+%~&]/, "")
                if (n.toLowerCase().indexOf(lower) === 0) {
                    out.push(n)
                }
            }
            page.tabMatches = out
        }
        if (page.tabMatches.length === 0) {
            return
        }
        var pick = page.tabMatches[page.tabIndex % page.tabMatches.length]
        page.tabIndex = (page.tabIndex + 1) % page.tabMatches.length
        var insert = (start === 0) ? (pick + ": ") : pick
        messageInput.text = text.substring(0, start) + insert + text.substring(pos)
        messageInput.cursorPosition = start + insert.length
    }

    // ---------------------------------------------------------------------- //
    // Join dialog (replaces the old bottom "Join a channel..." text field)
    // ---------------------------------------------------------------------- //
    function openJoinDialog()
    {
        joinDialog.open()
    }

    /// Canonical channel name: first whitespace-separated token, CR/LF
    /// stripped (protocol safety), and a "#" prefix ONLY for bare names —
    /// never forced onto the +, !, & channel types.
    function normalizeChannelName(raw)
    {
        var first = String(raw).trim().split(/\s+/)[0]
        if (first === undefined || first.length === 0) {
            return ""
        }
        var clean = first.replace(/[\r\n]+/g, "")
        if (clean.length === 0) {
            return ""
        }
        if (!page.isChannel(clean)) {
            clean = "#" + clean
        }
        return clean
    }

    /// Join `target` with an optional channel key (JOIN <channel> <key>).
    /// Used by the join dialog and by `/join #chan key` alike.
    function joinChannel(target, key)
    {
        var chan = page.normalizeChannelName(target)
        if (chan.length === 0 || page.bridge === null) {
            return
        }
        page.joinError = ""
        var k = String(key === undefined || key === null ? "" : key).replace(/[\r\n]+/g, "")
        if (k.length > 0) {
            page.bridge.send_raw("JOIN " + chan + " " + k)
        } else {
            page.bridge.join_channel(chan)
        }
        // Do not add the channel or switch to it until JOIN is accepted.
    }

    function submitJoinDialog()
    {
        var name = joinNameField.text.trim()
        if (name.length === 0) {
            return
        }
        var key = joinKeyField.text.replace(/[\r\n]+/g, "")
        if (key.trim().length === 0) {
            key = ""
        }
        var wantAutojoin = joinAutojoinBox.checked
        page.joinChannel(name, key)
        var listed = page.normalizeChannelName(name)
        if (listed.length > 0) {
            if (wantAutojoin) {
                page.addToAutojoin(listed)
            } else {
                page.removeFromAutojoin(listed)
            }
        }
    }

    /// appConfig.autojoin stays a COMMA-SEPARATED STRING (SettingsPage and
    /// applyAutojoin both parse that format).
    function addToAutojoin(channel)
    {
        var cfg = (page.hostWindow !== null && page.hostWindow !== undefined)
            ? page.hostWindow.appConfig : null
        if (cfg === null || cfg === undefined) {
            return
        }
        var list = String(cfg.autojoin || "").split(/[\s,]+/).filter(function (w) { return w.length > 0 })
        for (var i = 0; i < list.length; ++i) {
            if (page.sameTarget(list[i], channel)) {
                return
            }
        }
        list.push(channel)
        cfg.autojoin = list.join(", ")
        if (typeof cfg.save === "function") {
            cfg.save()
        }
    }

    function removeFromAutojoin(channel)
    {
        var cfg = (page.hostWindow !== null && page.hostWindow !== undefined)
            ? page.hostWindow.appConfig : null
        if (cfg === null || cfg === undefined) {
            return
        }
        var list = String(cfg.autojoin || "").split(/[\s,]+/).filter(function (w) { return w.length > 0 })
        var kept = list.filter(function (w) { return !page.sameTarget(w, channel) })
        if (kept.length === list.length) {
            return
        }
        cfg.autojoin = kept.join(", ")
        if (typeof cfg.save === "function") {
            cfg.save()
        }
    }

    // ---------------------------------------------------------------------- //
    // Lifecycle
    // ---------------------------------------------------------------------- //
    onCurrentChannelChanged: page.refreshHistory()

    Component.onCompleted: page.refreshHistory()
}
