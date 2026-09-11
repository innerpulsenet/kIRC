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

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

pragma ComponentBehavior: Bound

Kirigami.Page {
    id: page

    // Set by main.qml.
    property var bridge: null
    // The ApplicationWindow, so the header title can follow the active channel.
    property var hostWindow: null

    readonly property int timestampPointSize: ThemeEngine.resolvePointSize(ThemeEngine.timestampSize, Kirigami.Theme.defaultFont.pointSize)

    property string currentChannel: "#kirc"
    // Channels are hardcoded to start with; more get appended when a JOIN is
    // seen. TODO: hook a `channel_joined`/`channel_parted` signal from the
    // bridge once the C++ side exposes one.
    property var channels: ["#kirc"]

    readonly property string connectionLabel: {
        if (page.bridge === null) {
            return qsTr("No bridge")
        }
        switch (page.bridge.connection_state) {
        case 0: return qsTr("Disconnected")
        case 1: return qsTr("Connecting…")
        case 2: return qsTr("Connected")
        }
        return qsTr("Unknown")
    }

    title: page.currentChannel
    padding: 0

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
    // Layout
    // ---------------------------------------------------------------------- //
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- sidebar ---------------- //
        Rectangle {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
            Layout.minimumWidth: Kirigami.Units.gridUnit * 6
            Layout.fillHeight: true
            color: Kirigami.Theme.alternateBackgroundColor

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Controls.Label {
                    text: qsTr("Channels")
                    font.bold: true
                    color: Kirigami.Theme.disabledTextColor
                    topPadding: Kirigami.Units.smallSpacing
                    bottomPadding: Kirigami.Units.smallSpacing
                    leftPadding: Kirigami.Units.smallSpacing
                    Layout.fillWidth: true
                }

                ListView {
                    id: channelList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    currentIndex: page.channels.indexOf(page.currentChannel)
                    model: page.channels
                    reuseItems: true
                    cacheBuffer: Kirigami.Units.gridUnit * 10

                    delegate: Controls.ItemDelegate {
                        id: channelDelegate
                        required property string modelData
                        required property int index

                        width: channelList.width
                        text: channelDelegate.modelData
                        highlighted: channelDelegate.modelData === page.currentChannel
                        onClicked: page.openChannel(channelDelegate.modelData)
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Kirigami.Theme.disabledTextColor
                    opacity: 0.3
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Controls.TextField {
                        id: joinField
                        Layout.fillWidth: true
                        placeholderText: qsTr("#channel")
                        onAccepted: page.tryJoin()
                    }

                    Controls.ToolButton {
                        icon.name: "list-add"
                        text: qsTr("Join")
                        display: Controls.AbstractButton.IconOnly
                        onClicked: page.tryJoin()
                    }
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: Kirigami.Theme.textColor
            opacity: 0.15
        }

        // ---------------- message view ---------------- //
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Controls.Label {
                Layout.fillWidth: true
                leftPadding: Kirigami.Units.smallSpacing
                rightPadding: Kirigami.Units.smallSpacing
                topPadding: Kirigami.Units.smallSpacing / 2
                bottomPadding: Kirigami.Units.smallSpacing / 2
                text: {
                    var parts = [page.connectionLabel]
                    if (page.bridge !== null && page.bridge.connected_server.length > 0) {
                        parts.push(page.bridge.connected_server)
                    }
                    if (page.bridge !== null && page.bridge.nickname.length > 0) {
                        parts.push(page.bridge.nickname)
                    }
                    if (page.bridge !== null && page.bridge.unread_count > 0) {
                        parts.push(qsTr("%1 unread").arg(page.bridge.unread_count))
                    }
                    return parts.join(" · ")
                }
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideRight
                font.pointSize: page.timestampPointSize
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Kirigami.Theme.textColor
                opacity: 0.15
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

                // TODO(code-highlight): fenced code blocks are rendered as
                // plain text in pass 1 — wiring KSyntaxHighlighting needs a
                // C++ bridge.
                // The delegate picks up nick/text/timestamp/isSelf/isHighlight
                // straight from the model roles (see MessageDelegate).
                delegate: MessageDelegate { }

                Controls.Label {
                    anchors.centerIn: parent
                    visible: messageView.count === 0
                    text: page.bridge !== null && page.bridge.connection_state === 2
                          ? qsTr("No messages in %1 yet.").arg(page.currentChannel)
                          : qsTr("Not connected.")
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // ---------------- input ---------------- //
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: inputRow.implicitHeight + Kirigami.Units.largeSpacing
                color: Kirigami.Theme.backgroundColor

                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: Kirigami.Theme.textColor
                    opacity: 0.15
                }

                RowLayout {
                    id: inputRow
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Controls.TextField {
                        id: inputField
                        Layout.fillWidth: true
                        placeholderText: qsTr("Message %1").arg(page.currentChannel)
                        enabled: page.bridge !== null && page.bridge.connection_state === 2
                        onAccepted: page.sendCurrent()
                    }

                    Controls.Button {
                        text: qsTr("Send")
                        icon.name: "document-send"
                        enabled: inputField.enabled && inputField.text.length > 0
                        onClicked: page.sendCurrent()
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
        page.currentChannel = target
        if (page.hostWindow !== null && page.hostWindow !== undefined) {
            page.hostWindow.chatChannel = target
        }
        page.refreshHistory()
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
        var body = inputField.text
        if (body.length === 0 || page.bridge === null) {
            return
        }
        // Local echo is the bridge's job: it republishes what we send through
        // message_received(..., is_self = true), so nothing is appended here.
        page.bridge.send_message(page.currentChannel, body)
        inputField.text = ""
        // Keep focus so the user can keep typing.
        inputField.forceActiveFocus()
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
