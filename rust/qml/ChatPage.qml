// SPDX-License-Identifier: GPL-2.0-or-later
//
// ChatPage — channel sidebar + message view + input line.
//
// Bridge contract used here (cxx-qt keeps snake_case ids in QML):
//   IrcBridge:        connection_state, unread_count, nickname, connected_server
//                     signals: message_received(target, nick, text, is_self, is_highlight),
//                              history_batch_received(target), state_changed(state),
//                              notification_fired(title, body), info(text),
//                              error_occurred(message)
//                     invokables: connect_server(...), disconnect_server(),
//                                 send_message(target, text), request_history(target, limit)
//   MessageListModel: roles nick, text, timestamp, isSelf, isHighlight
//                     invokable load_channel(target)
//
// Layout (left to right): rounded-card sidebar (server entry + channels + join
// field), hairline, message list with an empty-state placeholder, and a
// floating input bar with an integrated accent send button.

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
    // Set when the pending reload carries our own echo: always scroll, even
    // if the user had scrolled up (their own line must be visible).
    property bool reloadSelf: false
    // Guards the post-identify GHOST+NICK reclaim: once per connection.
    property bool ghostDone: false

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
    // Model
    // ---------------------------------------------------------------------- //
    MessageListModel {
        id: msgModel
    }

    // New messages land in the model (rowsInserted) AND are announced through
    // message_received. Reloading the channel on every single message would be
    // O(history) per line, so the reload is coalesced through this timer.
    Timer {
        id: identifyTimer
        interval: 4000
        repeat: false
        onTriggered: page.applyAutojoin()
    }

    Timer {
        id: reloadTimer
        interval: 50
        repeat: false
        // Coalesced refresh for the open channel.  Autoscroll is conditional:
        // only pin to the bottom when the view is already there or the new
        // line is our own echo — never yank a user who scrolled up to read.
        onTriggered: {
            var stick = page.reloadSelf || messageView.atYEnd
            page.reloadSelf = false
            msgModel.load_channel(page.currentChannel)
            if (stick) {
                page.scrollToEnd()
            }
        }
    }

    Connections {
        target: page.bridge

        function onMessage_received(target, nick, text, is_self, is_highlight) {
            if (page.sameTarget(target, page.currentChannel)) {
                if (is_self) {
                    page.reloadSelf = true
                }
                if (!reloadTimer.running) {
                    reloadTimer.start()
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
        var out = []
        var previousKind = ""
        for (var i = 0; i < page.channels.length; ++i) {
            var target = page.channels[i]
            var isServer = (target === "*server*")
            var isQuery = !isServer && !page.isChannel(target)
            var kind = isServer ? "server" : (isQuery ? "query" : "channel")
            var title = isServer ? qsTr("Server") : (isQuery ? qsTr("Messages") : qsTr("Channels"))
            out.push({
                "target": target,
                "isServer": isServer,
                "isQuery": isQuery,
                "sectionTitle": title,
                "sectionStart": kind !== previousKind
            })
            previousKind = kind
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
        Rectangle {
            id: sidebar
            Layout.preferredWidth: ThemeEngine.sidebarWidthFor(Kirigami.Units.gridUnit)
            Layout.minimumWidth: Kirigami.Units.gridUnit * 9
            Layout.fillHeight: true
            color: Kirigami.Theme.alternateBackgroundColor

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
                    // joined channels. Section headers are part of the model,
                    // so a single flat list still renders as "Server" /
                    // "Channels".
                    delegate: Controls.ItemDelegate {
                        id: bufferDelegate
                        required property string target
                        required property bool isServer
                        required property bool isQuery
                        required property string sectionTitle
                        required property bool sectionStart

                        readonly property bool active: page.sameTarget(bufferDelegate.target, page.currentChannel)
                        readonly property color tileColor: bufferDelegate.isServer
                            ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.14)
                            : ThemeEngine.nickColor(bufferDelegate.target, page.darkTheme)

                        width: bufferList.width
                        hoverEnabled: true
                        padding: 0

                        onClicked: page.openChannel(bufferDelegate.target)

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: bufferDelegate.isServer
                            ? qsTr("Server messages and notices")
                            : bufferDelegate.target

                        background: Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                            anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: height / 2
                            color: bufferDelegate.active
                                ? ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.28)
                                : (bufferDelegate.hovered
                                   ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.08)
                                   : "transparent")
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: ColumnLayout {
                            spacing: 0

                            Controls.Label {
                                visible: bufferDelegate.sectionStart
                                text: bufferDelegate.sectionTitle
                                color: Kirigami.Theme.textColor
                                opacity: 0.65
                                font.bold: true
                                font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                                font.letterSpacing: 0.6
                                leftPadding: Kirigami.Units.smallSpacing * 2
                                topPadding: bufferDelegate.isServer ? 0 : Kirigami.Units.smallSpacing
                                bottomPadding: Kirigami.Units.smallSpacing
                                Layout.fillWidth: true
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                                Layout.rightMargin: Kirigami.Units.smallSpacing * 2
                                Layout.topMargin: Kirigami.Units.smallSpacing / 2
                                Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
                                spacing: Kirigami.Units.smallSpacing

                                // Rounded glyph tile: a server pictogram for the
                                // console, the channel's own hash colour for a
                                // channel (same colour as that channel's nicks).
                                Rectangle {
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.2)
                                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.2)
                                    radius: Kirigami.Units.cornerRadius

                                    color: bufferDelegate.isServer
                                        ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
                                        : bufferDelegate.tileColor

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
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    text: bufferDelegate.isServer
                                          ? page.serverBufferLabel
                                          : (bufferDelegate.isQuery
                                             ? bufferDelegate.target
                                             : bufferDelegate.target.substring(1))
                                    color: Kirigami.Theme.textColor
                                    font.bold: bufferDelegate.active
                                    elide: Text.ElideRight
                                }

                                Controls.ToolButton {
                                    visible: !bufferDelegate.isServer
                                    opacity: (bufferDelegate.hovered || bufferDelegate.active) ? 1 : 0
                                    icon.name: "window-close"
                                    display: Controls.AbstractButton.IconOnly
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.2)
                                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.2)
                                    onClicked: page.closeBuffer(bufferDelegate.target)
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

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: page.hairline
                }

                // ---------------- join field ---------------- //
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        id: joinFrame
                        Layout.fillWidth: true
                        implicitHeight: joinField.implicitHeight + Kirigami.Units.smallSpacing * 2
                        radius: Kirigami.Units.cornerRadius + 2
                        color: Kirigami.Theme.backgroundColor
                        border.width: 1
                        border.color: joinField.activeFocus ? Kirigami.Theme.highlightColor : page.hairline
                        Behavior on border.color {
                            ColorAnimation { duration: ThemeEngine.motionDuration }
                        }

                        Controls.TextField {
                            id: joinField
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing
                            background: null
                            placeholderText: qsTr("Join a channel…")
                            onAccepted: page.tryJoin()
                        }
                    }

                    Controls.Button {
                        id: joinButton
                        Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 1.6)
                        Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
                        enabled: joinField.text.trim().length > 0
                        onClicked: page.tryJoin()

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Join channel")

                        background: Rectangle {
                            radius: width / 2
                            color: !joinButton.enabled
                                ? "transparent"
                                : (joinButton.pressed
                                   ? Qt.darker(Kirigami.Theme.highlightColor, 1.2)
                                   : Kirigami.Theme.highlightColor)
                            border.width: 1
                            border.color: joinButton.enabled
                                ? "transparent"
                                : ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.5)
                            Behavior on color {
                                ColorAnimation { duration: ThemeEngine.motionDuration }
                            }
                        }

                        contentItem: Item {
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                source: "list-add"
                                // Full-strength colour: the style already dims
                                // a disabled control, and stacking another
                                // alpha on top makes the glyph invisible.
                                color: joinButton.enabled
                                    ? Kirigami.Theme.highlightedTextColor
                                    : Kirigami.Theme.disabledTextColor
                                width: Math.round(Kirigami.Units.gridUnit * 0.85)
                                height: width
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

            Rectangle {
                visible: page.currentTopic.length > 0 && page.isChannel(page.currentChannel)
                Layout.fillWidth: true
                implicitHeight: topicLabel.implicitHeight + Kirigami.Units.smallSpacing * 2
                color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.04)

                Controls.Label {
                    id: topicLabel
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    text: page.currentTopic
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    color: Kirigami.Theme.disabledTextColor
                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: page.hairline
                }
            }

            ListView {
                id: messageView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: msgModel
                reuseItems: true
                cacheBuffer: Kirigami.Units.gridUnit * 40
                spacing: 0
                topMargin: Kirigami.Units.smallSpacing
                bottomMargin: Kirigami.Units.smallSpacing
                // Keep self-message avatars out of the overlay scrollbar gutter.
                rightMargin: Kirigami.Units.smallSpacing * 2

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

            // ---------------- input ---------------- //
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: inputRow.implicitHeight + Kirigami.Units.smallSpacing * 2
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

                RowLayout {
                    id: inputRow
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        id: inputFrame
                        readonly property int pad: Math.round(Kirigami.Units.smallSpacing * 1.5)
                        readonly property int maxFieldHeight: Math.round(inputMetrics.lineSpacing * 5)

                        Layout.fillWidth: true
                        implicitHeight: Math.min(inputFrame.maxFieldHeight, messageInput.implicitHeight) + inputFrame.pad * 2
                        radius: Kirigami.Units.cornerRadius + 4
                        color: Kirigami.Theme.alternateBackgroundColor
                        border.width: 1
                        border.color: messageInput.activeFocus ? Kirigami.Theme.highlightColor : page.hairline
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
                                    return qsTr("/join #channel   /query nick   /quote …")
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
                                   ? Qt.darker(Kirigami.Theme.highlightColor, 1.2)
                                   : Kirigami.Theme.highlightColor)
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
                                // See the join button: no extra alpha on top of
                                // the style's own disabled dimming.
                                color: sendButton.enabled
                                    ? Kirigami.Theme.highlightedTextColor
                                    : Kirigami.Theme.disabledTextColor
                                width: Math.round(Kirigami.Units.gridUnit * 0.95)
                                height: width
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: page.isChannel(page.currentChannel)
            Layout.preferredWidth: Kirigami.Units.gridUnit * 9
            Layout.minimumWidth: Kirigami.Units.gridUnit * 7
            Layout.fillHeight: true
            color: Kirigami.Theme.alternateBackgroundColor

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Controls.Label {
                    text: qsTr("People (%1)").arg(page.nickList.length)
                    font.bold: true
                    color: Kirigami.Theme.disabledTextColor
                    leftPadding: Kirigami.Units.smallSpacing * 2
                    topPadding: Kirigami.Units.smallSpacing
                    bottomPadding: Kirigami.Units.smallSpacing
                    Layout.fillWidth: true
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: page.nickList
                    reuseItems: true
                    delegate: Controls.ItemDelegate {
                        required property string modelData
                        width: ListView.view.width
                        padding: Kirigami.Units.smallSpacing
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 0.9)
                                Layout.preferredHeight: Layout.preferredWidth
                                radius: width / 2
                                color: ThemeEngine.nickColor(modelData, page.darkTheme)
                                Controls.Label {
                                    anchors.centerIn: parent
                                    text: ThemeEngine.initial(modelData.replace(/^[@+%~&]/, ""))
                                    color: ThemeEngine.contrastingTextColor(parent.color)
                                    font.bold: true
                                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 3)
                                }
                            }
                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData
                                elide: Text.ElideRight
                                color: Kirigami.Theme.textColor
                            }
                        }
                        onClicked: {
                            var nick = modelData.replace(/^[@+%~&]/, "")
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
        page.refreshHistory()
        if (page.bridge !== null) {
            page.currentTopic = page.bridge.topic_for(target)
            var nicks = page.bridge.nicks_for(target)
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
        if (page.isChannel(target) && page.bridge !== null) {
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
            if (rest.length === 0) {
                return false
            }
            joinField.text = rest
            page.tryJoin()
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
            var bits = rest.split(" ")
            var nick = bits[0]
            if (!nick) {
                return false
            }
            page.addBuffer(nick)
            page.openChannel(nick)
            if (cmd === "/msg" && bits.length > 1) {
                page.bridge.send_message(nick, bits.slice(1).join(" "))
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
            var reason = kb.length > 1 ? kb.slice(1).join(" ") : ""
            page.bridge.send_raw("KICK " + page.currentChannel + " " + kb[0] + (reason ? (" :" + reason) : ""))
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
            page.bridge.clear_buffer(page.currentChannel)
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

    function tryJoin()
    {
        var target = joinField.text.trim()
        if (target.length === 0) {
            return
        }
        joinField.text = ""
        page.joinError = ""
        if (!page.isChannel(target)) {
            // A nick → query window. A bare word → treat as a channel.
            // Users type "pain" meaning "#pain"; they type a nick via /query.
            // Join attempts need a #-style prefix, but + and ! are real
            // channel types already — only add # when there is no prefix.
            target = "#" + target
        }
        if (page.bridge !== null) {
            page.bridge.join_channel(target)
        }
        // Do not add the channel or switch to it until JOIN is accepted.
    }

    // ---------------------------------------------------------------------- //
    // Lifecycle
    // ---------------------------------------------------------------------- //
    onCurrentChannelChanged: page.refreshHistory()

    Component.onCompleted: page.refreshHistory()
}
