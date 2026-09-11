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
// Layout (left to right): sidebar (box-drawing section rules + flat buffer
// rows + the `[+]` join control), 1px rule, message column (topic line framed
// by rules, flat log, boxed `> ` composer with a `[send]` control), and an
// optional people panel (rule header, `@nick` rows, ASCII sub-rules) for
// channels. Everything is monospace and flat — see the token block below.

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
    readonly property bool connected: page.bridge !== null && page.bridge.connection_state === 2
    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)

    // ---------------------------------------------------------------------- //
    // Retro-terminal chrome. Every colour comes from the frozen ThemeEngine
    // tokens via their resolvers (an empty token means "use the desktop
    // palette"); nothing on this page hardcodes a colour. `monoFamily` is the
    // theme's monospace family and drives the whole page through `font.family`
    // (controls inherit it).
    // ---------------------------------------------------------------------- //
    readonly property string monoFamily: ThemeEngine.fontFamily
    readonly property color fgPrimary: ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
    readonly property color fgDim: ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
    readonly property color fgAccent: ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor)
    readonly property color fgWarn: ThemeEngine.fgWarnColor(Kirigami.Theme.negativeTextColor)
    readonly property color bgPanel: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color bgLog: ThemeEngine.bgLogColor(Kirigami.Theme.backgroundColor)
    readonly property color bgInput: ThemeEngine.bgInputColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color ruleC: ThemeEngine.ruleColorValue(page.hairline)
    // Flat interaction tints (terminal selection band / hover), never rounded.
    readonly property color hoverFill: ThemeEngine.withAlpha(page.fgPrimary, 0.07)
    readonly property color selectionFill: ThemeEngine.withAlpha(page.fgAccent, 0.18)
    readonly property color pressFill: ThemeEngine.withAlpha(page.fgPrimary, 0.16)

    /// `── channels ───────── [5]` — the sidebar's section rule: a box-drawing
    /// run sized to `availableWidth` (via the mono font's metrics) with the
    /// count in brackets. `count` <= 0 drops the bracket.
    function sectionRule(title, count, availableWidth, metrics)
    {
        var suffix = count > 0 ? (" [" + count + "]") : ""
        var head = "── " + title + " "
        var dash = metrics.advanceWidth("─")
        var used = metrics.advanceWidth(head) + metrics.advanceWidth(suffix)
        var run = 2
        if (dash > 0) {
            run = Math.floor((availableWidth - used) / dash)
            if (run < 2) {
                run = 2
            }
        }
        var out = head
        for (var i = 0; i < run; ++i) {
            out += "─"
        }
        return out + suffix
    }

    /// `── Operators (2)` — the people panel's ASCII sub-rules.
    function subRule(title, count)
    {
        return "── " + title + " (" + count + ")"
    }

    /// Status rank of a nick-list prefix — the people panel's sort key:
    /// 0 owner/admin (`~` / `&`), 1 operator (`@`), 2 halfop (`%`),
    /// 3 voiced (`+`), 4 no status.  The core keeps these prefixes in the
    /// nick list (NAMES / is_channel), so all five cases are real input.
    function rankForPrefix(prefix)
    {
        if (prefix === "~" || prefix === "&") {
            return 0
        }
        if (prefix === "@") {
            return 1
        }
        if (prefix === "%") {
            return 2
        }
        if (prefix === "+") {
            return 3
        }
        return 4
    }

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
    // NickServ identify-on-connect was enabled but cannot run — no account, no
    // password, or both.  A sticky warning shown in the error banner, kept
    // apart from the transient join error so a later successful join cannot
    // wipe it; raised at most once per app session (see startIdentifyAndJoin).
    property string identifyWarning: ""
    property bool identifyWarningRaised: false
    /// What the error banner shows: the live join failure when there is one,
    /// otherwise the sticky NickServ warning.
    readonly property string bannerMessage: page.joinError.length > 0
                                           ? page.joinError : page.identifyWarning
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
    // One monospace family for the whole page: every control inherits this
    // unless it sets its own (the frozen `fontFamily` token).
    font.family: page.monoFamily

    /// "*server*" is a buffer name, not something to show the user verbatim.
    function channelLabel(target)
    {
        if (target === "*server*") {
            return qsTr("Server")
        }
        return target
    }

    // ---------------------------------------------------------------------- //
    // Geometry + legacy theme tokens still in use (see the retro-terminal
    // token block at the top of the page for the colours).
    // ---------------------------------------------------------------------- //
    readonly property real sideWidth: ThemeEngine.sidebarWidth > 0 ? ThemeEngine.sidebarWidth : 250
    readonly property real rowHt: ThemeEngine.rowHeight
    readonly property color mutedTxt: ThemeEngine.mutedTextColor(Kirigami.Theme.disabledTextColor)
    readonly property color sectionTxt: ThemeEngine.sectionHeaderColor(Kirigami.Theme.textColor)
    readonly property int sectionSz: ThemeEngine.resolveSectionHeaderSize(Kirigami.Theme.defaultFont.pointSize)
    readonly property int eventSz: ThemeEngine.resolveEventSize(Kirigami.Theme.defaultFont.pointSize)

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
                // Identify actually went through: the credential warning (if
                // any) is stale now.
                page.identifyWarning = ""
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

    /// People panel model, derived from the channel's nick list: one section
    /// per status rank — owner/admin (`~` / `&`), operators (`@`), halfops
    /// (`%`), voiced (`+`) and everyone else — ranks in that order, members
    /// alphabetical (case-insensitive) inside each rank, filtered live by the
    /// panel's search field.  A rank with no members contributes no section at
    /// all (no rule, no count) and the ASCII prefix stays inline on every row.
    readonly property var peopleEntries: {
        var filter = page.peopleFilter.trim().toLowerCase()
        var titles = [qsTr("Owner & Admin"), qsTr("Operators"), qsTr("Halfops"),
                      qsTr("Voiced"), qsTr("Others")]
        var ranks = [[], [], [], [], []]
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
            ranks[page.rankForPrefix(prefix)].push({
                "nick": raw, "bare": bare, "prefix": prefix, "group": ""
            })
        }
        function byBare(a, b) {
            var x = String(a.bare).toLowerCase()
            var y = String(b.bare).toLowerCase()
            return x < y ? -1 : (x > y ? 1 : 0)
        }
        var out = []
        for (var r = 0; r < ranks.length; ++r) {
            if (ranks[r].length === 0) {
                continue
            }
            ranks[r].sort(byBare)
            // ASCII sub-rules (`── Operators (2)`) instead of a messenger-style
            // section caption; the delegate renders `group` verbatim.  Every
            // member of a rank carries the same rule, so the ListView section
            // boundary falls between ranks, after the alphabetical sort.
            var rule = page.subRule(titles[r], ranks[r].length)
            for (var j = 0; j < ranks[r].length; ++j) {
                ranks[r][j].group = rule
                out.push(ranks[r][j])
            }
        }
        return out
    }

    // ---------------------------------------------------------------------- //
    // Layout
    // ---------------------------------------------------------------------- //
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- sidebar ---------------- //
        // Flat terminal list: full-bleed rows, box-drawing section rules with
        // the count in brackets, a `▌` marker + flat accent band for the open
        // buffer, an ASCII `*` for unread. No pills, no tiles, no avatars; the
        // hover-revealed close stays inside its row's reserved slot.
        Rectangle {
            id: sidebar
            Layout.preferredWidth: page.sideWidth
            Layout.minimumWidth: Kirigami.Units.gridUnit * 9
            Layout.fillHeight: true
            color: page.bgPanel

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
                    // joined channels and query windows. Section rules are part
                    // of the model, so a single flat list still renders as
                    // "Server" / "Messages" / "Channels".
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
                        // Plain buffer name as it is typed (`#pain`, a query
                        // nick); the console row shows the network it is on.
                        readonly property string rowLabel: bufferDelegate.isServer
                            ? page.serverBufferLabel : bufferDelegate.target
                        // Width the section rule may occupy: the row minus its
                        // margins, minus the `[+]` join control's slot on the
                        // Channels rule.
                        readonly property real ruleWidth: Math.max(0, bufferDelegate.width
                            - Kirigami.Units.smallSpacing * 4
                            - (bufferDelegate.sectionKind === "channel"
                               ? Math.round(Kirigami.Units.gridUnit * 1.9) : 0))

                        width: bufferList.width
                        hoverEnabled: true
                        padding: 0
                        // The close control is overlaid inside this row: it
                        // must never paint outside the row's bounds.
                        clip: true
                        font.family: page.monoFamily

                        onClicked: page.openChannel(bufferDelegate.target)

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: bufferDelegate.isServer
                            ? qsTr("Server messages and notices")
                            : bufferDelegate.target

                        FontMetrics {
                            id: bufferMetrics
                            font.family: page.monoFamily
                            font.pointSize: page.sectionSz
                        }

                        background: Rectangle {
                            // Full-bleed flat band: accent tint for the open
                            // buffer, a faint wash on hover. Never rounded.
                            color: bufferDelegate.active
                                ? page.selectionFill
                                : (bufferDelegate.hovered ? page.hoverFill : "transparent")
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: ColumnLayout {
                            spacing: 0

                            // Section rule: `── channels ────────── [5]`
                            RowLayout {
                                visible: bufferDelegate.sectionStart
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                                Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                                Layout.topMargin: bufferDelegate.isServer
                                                 ? Kirigami.Units.smallSpacing / 2
                                                 : Kirigami.Units.smallSpacing
                                Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    text: page.sectionRule(bufferDelegate.sectionTitle,
                                                           bufferDelegate.sectionCount,
                                                           bufferDelegate.ruleWidth,
                                                           bufferMetrics)
                                    color: page.sectionTxt
                                    opacity: 0.85
                                    font.family: page.monoFamily
                                    font.pointSize: page.sectionSz
                                    elide: Text.ElideRight
                                }

                                // Join action: lives in the Channels rule row
                                // (next to the count), not beside any buffer's
                                // close control. Flat `[+]`, no surface box.
                                Controls.ToolButton {
                                    id: joinAddButton
                                    visible: bufferDelegate.sectionKind === "channel"
                                    display: Controls.AbstractButton.TextOnly
                                    text: qsTr("[+]")
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.9)
                                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.25)
                                    onClicked: page.openJoinDialog()

                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.text: qsTr("Join a channel (Ctrl+J)")

                                    contentItem: Controls.Label {
                                        text: joinAddButton.text
                                        color: joinAddButton.hovered || joinAddButton.activeFocus
                                               ? page.fgAccent : page.fgPrimary
                                        font.family: page.monoFamily
                                        font.bold: true
                                        font.pointSize: page.sectionSz
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    background: Rectangle {
                                        color: joinAddButton.hovered || joinAddButton.activeFocus
                                               ? page.hoverFill : "transparent"
                                        Behavior on color {
                                            ColorAnimation { duration: ThemeEngine.motionDuration }
                                        }
                                    }
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
                                    // outside the row.
                                    anchors.rightMargin: Math.round(Kirigami.Units.gridUnit * 1.25) + Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing / 2

                                    // Leading selection marker: a `▌` bar on
                                    // the open buffer, one blank cell on every
                                    // other row so names stay in one column.
                                    Controls.Label {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: bufferDelegate.active ? "\u258c" : " "
                                        color: page.fgAccent
                                        font.family: page.monoFamily
                                    }

                                    Controls.Label {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        // Plain text: `#pain`, the query nick,
                                        // or the console's network name. No
                                        // tile, no avatar, no prefix stripping.
                                        text: bufferDelegate.rowLabel
                                        color: page.fgPrimary
                                        font.family: page.monoFamily
                                        font.bold: bufferDelegate.active || bufferDelegate.hasUnread
                                        elide: Text.ElideRight
                                    }

                                    // Unread marker: ASCII `*` (the core only
                                    // tracks a global counter, so every
                                    // non-visible buffer carries the marker
                                    // while it is non-zero).
                                    Controls.Label {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: bufferDelegate.hasUnread
                                        text: "*"
                                        color: page.fgAccent
                                        font.family: page.monoFamily
                                        font.bold: true

                                        Controls.ToolTip.visible: unreadHover.hovered
                                        Controls.ToolTip.text: page.bridge !== null
                                            ? qsTr("%n unread message(s)", "", page.bridge.unread_count) : ""

                                        HoverHandler {
                                            id: unreadHover
                                        }
                                    }
                                }

                                // The close control is OVERLAID at the row's
                                // right edge (slot always reserved via the
                                // inner row's right margin): it only fades in
                                // on hover or keyboard focus, so it can never
                                // shove the log or float outside the row.
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
                                    display: Controls.AbstractButton.TextOnly
                                    text: "\u00d7"
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

                                    contentItem: Controls.Label {
                                        text: closeButton.text
                                        color: closeButton.hovered || closeButton.activeFocus
                                               ? page.fgWarn : page.fgDim
                                        font.family: page.monoFamily
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    background: Rectangle {
                                        color: closeButton.hovered || closeButton.activeFocus
                                               ? page.hoverFill : "transparent"
                                    }
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
                            color: ThemeEngine.withAlpha(page.fgDim,
                                                         channelScroll.pressed ? 0.55 : 0.3)
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
            color: page.ruleC
        }

        // ---------------- message view ---------------- //
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Error banner: a flat terminal warning line (`[!] message ×`) with
            // a warn-coloured rule instead of a rounded inline message surface.
            // Carries the live join failure, or — when there is none — the
            // sticky NickServ-identify misconfiguration warning.
            Rectangle {
                id: joinErrorBar
                Layout.fillWidth: true
                visible: page.bannerMessage.length > 0
                implicitHeight: joinErrorRow.implicitHeight + Kirigami.Units.smallSpacing
                color: page.bgPanel

                Controls.ToolTip.visible: joinErrorHover.hovered
                Controls.ToolTip.text: page.bannerMessage

                HoverHandler {
                    id: joinErrorHover
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.fgWarn
                    opacity: 0.6
                }

                RowLayout {
                    id: joinErrorRow
                    anchors.fill: parent
                    anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: "[!]"
                        color: page.fgWarn
                        font.family: page.monoFamily
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: page.bannerMessage
                        color: page.fgWarn
                        font.family: page.monoFamily
                        font.pointSize: page.eventSz
                        elide: Text.ElideRight
                    }

                    Controls.ToolButton {
                        id: joinErrorClose
                        Layout.alignment: Qt.AlignVCenter
                        display: Controls.AbstractButton.TextOnly
                        text: "\u00d7"
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.25)
                        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.25)
                        onClicked: {
                            // Dismiss what is shown: a live join failure first,
                            // then the sticky identify warning.
                            if (page.joinError.length > 0) {
                                page.joinError = ""
                            } else {
                                page.identifyWarning = ""
                            }
                        }
                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Dismiss")

                        contentItem: Controls.Label {
                            text: joinErrorClose.text
                            color: joinErrorClose.hovered ? page.fgWarn : page.fgDim
                            font.family: page.monoFamily
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        background: Rectangle {
                            color: joinErrorClose.hovered ? page.hoverFill : "transparent"
                        }
                    }
                }
            }

            // Topic bar: a terminal line — `#pain │ topic` — framed by
            // box-drawing rules instead of a rounded surface, with the
            // people-panel toggle docked at its right end as a small ASCII
            // control.
            Rectangle {
                id: topicBar
                visible: page.isChannel(page.currentChannel)
                Layout.fillWidth: true
                implicitHeight: topicLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
                color: page.bgPanel

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
                    color: page.ruleC
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
                    spacing: Kirigami.Units.smallSpacing / 2

                    // `#pain` — the channel as it is typed (no colour tile).
                    Controls.Label {
                        id: topicName
                        Layout.alignment: Qt.AlignVCenter
                        Layout.maximumWidth: Math.round(topicBar.width * 0.45)
                        text: page.currentChannel
                        color: page.fgPrimary
                        font.family: page.monoFamily
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    // Dim `│` separator between the channel and its topic.
                    Controls.Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: "│"
                        color: page.fgDim
                        font.family: page.monoFamily
                    }

                    // Topic: one elided line by default; word-wrapped while
                    // expanded, capped at a few lines so a pathological topic
                    // can never squeeze the log/composer out of the window.
                    Controls.Label {
                        id: topicLabel
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        Layout.leftMargin: Kirigami.Units.smallSpacing / 2
                        textFormat: Text.PlainText
                        text: page.currentTopic.length > 0 ? page.currentTopic : qsTr("No topic set")
                        font.family: page.monoFamily
                        font.italic: page.currentTopic.length === 0
                        maximumLineCount: page.topicExpanded ? 6 : 1
                        elide: Text.ElideRight
                        wrapMode: page.topicExpanded ? Text.WordWrap : Text.NoWrap
                        color: page.currentTopic.length > 0 ? page.fgPrimary : page.mutedTxt
                        font.pointSize: page.eventSz
                    }

                    // People-panel toggle: a small ASCII control docked at the
                    // bar's right end (accent while the panel is shown).
                    Controls.ToolButton {
                        id: peopleToggle
                        Layout.alignment: Qt.AlignVCenter
                        display: Controls.AbstractButton.TextOnly
                        text: "[" + qsTr("people") + "]"
                        checkable: true
                        checked: page.peopleVisible
                        onToggled: page.peopleVisible = checked

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: checked ? qsTr("Hide people panel") : qsTr("Show people panel")

                        contentItem: Controls.Label {
                            text: peopleToggle.text
                            color: peopleToggle.checked ? page.fgAccent
                                   : (peopleToggle.hovered || peopleToggle.activeFocus ? page.fgPrimary : page.fgDim)
                            font.family: page.monoFamily
                            font.pointSize: page.eventSz
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        background: Rectangle {
                            color: peopleToggle.hovered || peopleToggle.activeFocus
                                   ? page.hoverFill : "transparent"
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.ruleC
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Flat log surface (the `bgLog` token); the delegate paints
                // the text rows on top of it.
                Rectangle {
                    anchors.fill: parent
                    color: page.bgLog
                }

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
                    // Keep self-message rows out of the overlay scrollbar gutter.
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
                            color: ThemeEngine.withAlpha(page.fgDim,
                                                         messageScroll.pressed ? 0.55 : 0.3)
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

                        // ASCII banner instead of a modern pictogram.
                        Controls.Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: !page.connected ? "[ offline ]"
                                  : (page.currentChannel === "*server*" ? "[ server console ]"
                                     : "[" + page.currentChannel + "]")
                            color: page.fgDim
                            font.family: page.monoFamily
                            font.pointSize: page.eventSz
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
                            color: page.fgPrimary
                            font.family: page.monoFamily
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
                            color: page.mutedTxt
                            font.family: page.monoFamily
                        }
                    }
                }

                // Flat ASCII control: traffic arrived while scrolled up.
                Controls.Button {
                    id: newMessagesPill
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Kirigami.Units.smallSpacing * 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: page.hasUnseenBelow
                    z: 2
                    text: "[ " + qsTr("new messages") + " ]"
                    onClicked: {
                        page.hasUnseenBelow = false
                        page.scrollToEnd()
                    }

                    background: Rectangle {
                        color: newMessagesPill.pressed ? page.pressFill : page.bgPanel
                        border.width: 1
                        border.color: page.fgAccent
                        Behavior on color {
                            ColorAnimation { duration: ThemeEngine.motionDuration }
                        }
                    }

                    contentItem: Controls.Label {
                        text: newMessagesPill.text
                        color: page.fgAccent
                        font.family: page.monoFamily
                        font.bold: true
                        font.pointSize: page.eventSz
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: Kirigami.Units.smallSpacing
                        rightPadding: Kirigami.Units.smallSpacing
                    }
                }
            }

            // ---------------- input ---------------- //
            // The composer is the last row of the message column: the log
            // above it is Layout.fillHeight, so the list absorbs every resize
            // and this bar keeps its implicit height (the "new messages"
            // control lives inside the log, so it can never push anything out
            // either).  The extra bottom inset keeps the input frame visibly
            // clear of the window's bottom edge instead of running into it.
            //
            // Terminal composer: a flat 1px-boxed field with a `>` prompt
            // prefix and a plain `[send]` control — no rounded pill, no round
            // send button.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: inputColumn.implicitHeight + Kirigami.Units.smallSpacing * 3
                color: page.bgLog

                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: page.ruleC
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
                        color: page.fgDim
                        font.family: page.monoFamily
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
                            radius: 0
                            color: page.bgInput
                            border.width: 1
                            border.color: messageInput.activeFocus ? page.fgAccent : page.ruleC
                            Behavior on border.color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }

                            // `> ` prompt: the terminal cursor line, ahead of
                            // the editable text (never inside its content).
                            Controls.Label {
                                id: inputPrompt
                                anchors.left: parent.left
                                anchors.leftMargin: inputFrame.pad
                                anchors.verticalCenter: parent.verticalCenter
                                text: ">"
                                color: messageInput.activeFocus ? page.fgAccent : page.fgDim
                                font.family: page.monoFamily
                            }

                            Controls.TextArea {
                                id: messageInput
                                anchors.left: inputPrompt.right
                                anchors.right: parent.right
                                anchors.leftMargin: Math.round(Kirigami.Units.smallSpacing / 2)
                                anchors.rightMargin: inputFrame.pad
                                anchors.verticalCenter: parent.verticalCenter
                                height: Math.min(inputFrame.maxFieldHeight, implicitHeight)

                                background: null
                                leftPadding: 0
                                rightPadding: 0
                                topPadding: 0
                                bottomPadding: 0
                                font.family: page.monoFamily

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

                        // Flat `[send]` control (disabled while the console is
                        // active or the field is empty).
                        Controls.Button {
                            id: sendButton
                            Layout.alignment: Qt.AlignBottom
                            Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 2.5)
                            Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.9)
                            enabled: page.connected && page.currentChannel !== "*server*" && messageInput.text.trim().length > 0
                            onClicked: page.sendCurrent()
                            text: qsTr("[send]")

                            Controls.ToolTip.visible: hovered
                            Controls.ToolTip.text: qsTr("Send message")

                            background: Rectangle {
                                radius: 0
                                color: sendButton.pressed ? page.pressFill
                                       : (sendButton.hovered ? page.hoverFill : "transparent")
                                border.width: 1
                                border.color: sendButton.enabled ? page.fgAccent : page.ruleC
                                Behavior on color {
                                    ColorAnimation { duration: ThemeEngine.motionDuration }
                                }
                            }

                            contentItem: Controls.Label {
                                text: sendButton.text
                                color: sendButton.enabled ? page.fgAccent : page.mutedTxt
                                font.family: page.monoFamily
                                font.pointSize: page.eventSz
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }
        }

        // ---------------- people panel ---------------- //
        // Plain monospace list: rule header with the count, one `@nick` /
        // `+nick` row per person (the mode prefix is inline text), ASCII
        // sub-rules per rank group, dim for anyone without a rank. No
        // avatars, no badge column, no round surfaces.
        Rectangle {
            id: peoplePanel
            // Auto-hide on a narrow window: with a 250px sidebar plus this
            // panel there is not enough room left for the log to stay
            // readable, and squeezing it pushed the panel past the window
            // edge.  The topic-bar toggle still works whenever it is shown.
            visible: page.isChannel(page.currentChannel) && page.peopleVisible
                     && (page.width - page.sideWidth) >= page.peoplePanelMinSpace
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.minimumWidth: Kirigami.Units.gridUnit * 8
            Layout.fillHeight: true
            color: page.bgPanel

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                FontMetrics {
                    id: peopleMetrics
                    font.family: page.monoFamily
                    font.pointSize: page.sectionSz
                }

                // `── People ──────── [5]`
                Controls.Label {
                    text: page.sectionRule(qsTr("People"), page.peopleEntries.length,
                                           Math.max(0, peoplePanel.width - Kirigami.Units.smallSpacing * 4),
                                           peopleMetrics)
                    color: page.sectionTxt
                    opacity: 0.85
                    font.family: page.monoFamily
                    font.pointSize: page.sectionSz
                    leftPadding: Kirigami.Units.smallSpacing * 2
                    rightPadding: Kirigami.Units.smallSpacing * 2
                    topPadding: Kirigami.Units.smallSpacing
                    bottomPadding: Kirigami.Units.smallSpacing / 2
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // Flat boxed filter with a `>` prompt.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                    Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    implicitHeight: peopleFilterField.implicitHeight + Kirigami.Units.smallSpacing
                    radius: 0
                    color: page.bgInput
                    border.width: 1
                    border.color: peopleFilterField.activeFocus ? page.fgAccent : page.ruleC
                    Behavior on border.color {
                        ColorAnimation { duration: ThemeEngine.motionDuration }
                    }

                    Controls.Label {
                        id: peopleFilterPrompt
                        anchors.left: parent.left
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.verticalCenter: parent.verticalCenter
                        text: ">"
                        color: peopleFilterField.activeFocus ? page.fgAccent : page.fgDim
                        font.family: page.monoFamily
                        font.pointSize: page.eventSz
                    }

                    Controls.TextField {
                        id: peopleFilterField
                        anchors.left: peopleFilterPrompt.right
                        anchors.right: parent.right
                        anchors.leftMargin: Kirigami.Units.smallSpacing / 2
                        anchors.rightMargin: Kirigami.Units.smallSpacing
                        anchors.verticalCenter: parent.verticalCenter
                        leftPadding: 0
                        rightPadding: 0
                        background: null
                        font.family: page.monoFamily
                        font.pointSize: page.eventSz
                        placeholderText: qsTr("filter…")
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
                    // ASCII sub-rule per rank group: `── Operators (2)`.
                    section.delegate: Controls.Label {
                        required property string section
                        width: peopleList.width
                        text: section
                        color: page.fgDim
                        font.family: page.monoFamily
                        font.pointSize: page.eventSz
                        leftPadding: Kirigami.Units.smallSpacing * 2
                        topPadding: Kirigami.Units.smallSpacing / 2
                        bottomPadding: Kirigami.Units.smallSpacing / 2
                        elide: Text.ElideRight
                    }

                    delegate: Controls.ItemDelegate {
                        id: personDelegate
                        required property string nick
                        required property string bare
                        required property string prefix

                        // Rank drives the weight: operators stay at full
                        // foreground, everyone else (voiced included) is dim.
                        readonly property bool isOp: personDelegate.prefix === "@"
                            || personDelegate.prefix === "%"
                            || personDelegate.prefix === "~"
                            || personDelegate.prefix === "&"

                        width: peopleList.width
                        hoverEnabled: true
                        padding: 0
                        clip: true
                        implicitHeight: page.rowHt
                        font.family: page.monoFamily

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: personDelegate.nick

                        background: Rectangle {
                            // Flat, full-bleed hover wash — never rounded.
                            color: personDelegate.hovered ? page.hoverFill : "transparent"
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: Controls.Label {
                            leftPadding: Kirigami.Units.smallSpacing * 2
                            rightPadding: Kirigami.Units.smallSpacing * 2
                            verticalAlignment: Text.AlignVCenter
                            // `@nick` / `+nick` inline: the mode prefix is
                            // part of the text, never a separate badge column.
                            text: personDelegate.nick
                            color: personDelegate.isOp ? page.fgPrimary : page.mutedTxt
                            font.family: page.monoFamily
                            elide: Text.ElideRight
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

    /// NickServ IDENTIFY is enabled but there is nothing to send — say exactly
    /// which credential is missing in the error banner instead of silently
    /// skipping the identify and letting a later join failure be the only
    /// clue.  Raised once per app session: a reconnect must not re-raise it.
    function warnIdentifyCredentialsMissing(missingAccount, missingPassword)
    {
        if (page.identifyWarningRaised) {
            return
        }
        page.identifyWarningRaised = true
        var missing = missingAccount && missingPassword
            ? qsTr("no account or password is set")
            : (missingAccount ? qsTr("no account is set") : qsTr("no password is set"))
        page.identifyWarning = qsTr("NickServ identify is on but %1 — open Settings > Identity").arg(missing)
    }

    function startIdentifyAndJoin()
    {
        if (page.bridge === null) {
            return
        }
        var cfg = (page.hostWindow !== null) ? page.hostWindow.appConfig : null
        if (cfg !== null && cfg !== undefined && cfg.identifyOnConnect) {
            var account = page.nickservAccount()
            var password = (cfg.nickservPassword === undefined || cfg.nickservPassword === null)
                ? "" : String(cfg.nickservPassword)
            if (account.length === 0 || password.length === 0) {
                // Identify is on but cannot be sent: surface what is missing
                // in the banner, then run the joins as before.
                page.warnIdentifyCredentialsMissing(account.length === 0, password.length === 0)
                page.applyAutojoin()
                return
            }
            page.bridge.send_raw("PRIVMSG NickServ :IDENTIFY " + account + " " + password)
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
