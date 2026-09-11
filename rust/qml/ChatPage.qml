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

    property string currentChannel: "#kirc"
    // The server console (numerics, MOTD, joins/parts) lives in a dedicated
    // "*server*" buffer the bridge fills; channels join it in the sidebar.
    property var channels: ["*server*", "#kirc"]

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
        id: reloadTimer
        interval: 50
        repeat: false
        onTriggered: page.refreshHistory()
    }

    Connections {
        target: page.bridge

        function onMessage_received(target, nick, text, is_self, is_highlight) {
            if (target === page.currentChannel) {
                if (!reloadTimer.running) {
                    reloadTimer.start()
                }
            }
        }

        function onHistory_batch_received(target) {
            if (target === page.currentChannel) {
                Qt.callLater(page.scrollToEnd)
            }
        }

        function onState_changed(state) {
            if (state === 2) {
                page.refreshHistory()
            }
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
        for (var i = 0; i < page.channels.length; ++i) {
            var target = page.channels[i]
            var isServer = (target === "*server*")
            var previousIsServer = i > 0 && page.channels[i - 1] === "*server*"
            out.push({
                "target": target,
                "isServer": isServer,
                "sectionTitle": isServer ? qsTr("Server") : qsTr("Channels"),
                "sectionStart": i === 0 || isServer !== previousIsServer
            })
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
                        required property string sectionTitle
                        required property bool sectionStart

                        readonly property bool active: bufferDelegate.target === page.currentChannel
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
                                        text: "#"
                                        color: ThemeEngine.contrastingTextColor(bufferDelegate.tileColor)
                                        font.bold: true
                                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize)
                                    }
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    text: bufferDelegate.isServer
                                        ? page.serverBufferLabel
                                        : bufferDelegate.target.substring(1)
                                    color: Kirigami.Theme.textColor
                                    font.bold: bufferDelegate.active
                                    elide: Text.ElideRight
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

                            enabled: page.connected && page.currentChannel !== "*server*"
                            placeholderText: {
                                if (!page.connected) {
                                    return qsTr("Connect to a server to send messages")
                                }
                                if (page.currentChannel === "*server*") {
                                    return qsTr("Server console — messages can't be sent here")
                                }
                                return qsTr("Message %1").arg(page.currentChannel)
                            }
                            wrapMode: Controls.TextArea.Wrap
                            selectByMouse: true

                            // Enter sends, Shift+Enter inserts a newline. The
                            // event is left unaccepted for the shifted case so
                            // the TextArea's own handling adds the break.
                            Keys.onPressed: (event) => {
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
    }

    // ---------------------------------------------------------------------- //
    // Actions
    // ---------------------------------------------------------------------- //
    function openChannel(target)
    {
        if (target === undefined || target === null || target.length === 0) {
            return
        }
        var switching = target !== page.currentChannel
        page.currentChannel = target
        if (page.hostWindow !== null && page.hostWindow !== undefined) {
            page.hostWindow.chatChannel = target
        }
        page.refreshHistory()
        if (switching) {
            contentFade.restart()
        }
    }

    function refreshHistory()
    {
        msgModel.load_channel(page.currentChannel)
        page.scrollToEnd()
    }

    function scrollToEnd()
    {
        messageView.positionViewAtEnd()
    }

    function sendCurrent()
    {
        var body = messageInput.text.trim()
        if (body.length === 0 || page.bridge === null || page.currentChannel === "*server*") {
            return
        }
        // Local echo is the bridge's job: it republishes what we send through
        // message_received(..., is_self = true), so nothing is appended here.
        page.bridge.send_message(page.currentChannel, body)
        messageInput.text = ""
        // Keep focus so the user can keep typing.
        messageInput.forceActiveFocus()
    }

    function tryJoin()
    {
        var target = joinField.text.trim()
        if (target.length === 0) {
            return
        }
        if (target.charAt(0) !== "#" && target.charAt(0) !== "&") {
            target = "#" + target
        }
        joinField.text = ""
        var list = page.channels.slice()
        if (list.indexOf(target) === -1) {
            list.push(target)
            page.channels = list
        }
        // TODO: the C++ bridge has no join_channel() in the current contract.
        // Guarded call so this keeps working once it is added.
        if (page.bridge !== null && typeof page.bridge.join_channel === "function") {
            page.bridge.join_channel(target)
        }
        page.openChannel(target)
        page.bridge.request_history(target, 200)
    }

    // ---------------------------------------------------------------------- //
    // Lifecycle
    // ---------------------------------------------------------------------- //
    onCurrentChannelChanged: page.refreshHistory()

    Component.onCompleted: page.refreshHistory()
}
