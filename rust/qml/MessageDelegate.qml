// SPDX-License-Identifier: GPL-2.0-or-later
//
// MessageDelegate — one IRC message.
//
// Two rendering modes, driven by `styleMode` (which ChatPage derives from
// ThemeEngine.mode):
//   0 = dense  : classic "<time> <nick> text" IRC line
//   1 = bubble : rounded bubbles, own messages right-aligned in accent colour
//
// Sizing: the root is an Item whose implicitHeight follows the content
// column, so ListView sizes rows correctly. `width` binds to the hosting
// ListView (falling back to implicit sizing when previewed standalone).

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

Item {
    id: delegate

    // --- public API (initialised from the model roles by ListView) ---------
    // Names must match MessageListModel.roleNames() exactly. They are
    // `required`, so a role-name mismatch fails loudly at delegate creation
    // (visible in the log) instead of silently rendering empty rows.
    required property string nick
    required property string text
    required property var timestamp
    required property bool isSelf
    required property bool isHighlight

    // 0 = dense, 1 = bubble. Follows the active theme; can be overridden from
    // JS if a caller wants to force one style.
    property int styleMode: ThemeEngine.mode === "bubble" ? 1 : 0

    // --- theme / palette ---------------------------------------------------
    // Kirigami's attached property must be read from inside an Item to inherit
    // the window's colorSet, which is why the dark/light test happens here and
    // not inside the ThemeEngine singleton.
    readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
    readonly property color nickColorValue: ThemeEngine.nickColor(delegate.nick, delegate.darkTheme)
    readonly property color visibleNickColor: delegate.isHighlight ? Kirigami.Theme.highlightColor : delegate.nickColorValue

    readonly property bool themeProvidesSelfColor: ThemeEngine.selfColor !== ""
    readonly property color bubbleColor: delegate.isSelf
        ? ThemeEngine.selfBubbleColor(Kirigami.Theme.highlightColor)
        : ThemeEngine.otherBubbleColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color bubbleTextColor: (delegate.isSelf && !delegate.themeProvidesSelfColor)
        ? Kirigami.Theme.highlightedTextColor
        : Kirigami.Theme.textColor

    readonly property int messagePointSize: ThemeEngine.resolvePointSize(ThemeEngine.messageSize, Kirigami.Theme.defaultFont.pointSize)
    readonly property int timestampPointSize: ThemeEngine.resolvePointSize(ThemeEngine.timestampSize, Kirigami.Theme.defaultFont.pointSize)

    readonly property int hMargin: Kirigami.Units.smallSpacing
    readonly property int hMarginWithStripe: hMargin + stripe.width + Kirigami.Units.smallSpacing

    // Widest a wrapped bubble text may get before it wraps.
    readonly property real maxTextWidth: Math.max(Kirigami.Units.gridUnit * 6, delegate.width * 0.75 - hMargin * 2)

    width: ListView.view ? ListView.view.width : implicitWidth
    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

    // Accent stripe for highlight (nick mention) messages.
    Rectangle {
        id: stripe
        visible: delegate.isHighlight
        width: 3
        color: Kirigami.Theme.highlightColor
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: stripe.visible ? delegate.hMarginWithStripe : delegate.hMargin
        anchors.rightMargin: delegate.hMargin
        spacing: delegate.styleMode === 1 ? ThemeEngine.bubbleSpacing : ThemeEngine.denseLineSpacing

        // ---------------------------------------------------------------- //
        // Dense IRC line
        // TODO(code-highlight): syntax-highlight fenced code blocks (needs a
        // KSyntaxHighlighting bridge on the C++ side; out of scope for pass 1).
        // ---------------------------------------------------------------- //
        RowLayout {
            visible: delegate.styleMode === 0
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                text: delegate.timestamp
                color: Kirigami.Theme.disabledTextColor
                font.pointSize: delegate.timestampPointSize
                Layout.alignment: Qt.AlignTop
            }

            Controls.Label {
                text: (delegate.nick.length > 0 ? delegate.nick : qsTr("*")) + ":"
                color: delegate.visibleNickColor
                font.bold: true
                font.pointSize: delegate.messagePointSize
                Layout.alignment: Qt.AlignTop
            }

            Kirigami.SelectableLabel {
                id: denseText
                text: ThemeEngine.formatMessage(delegate.text)
                textFormat: Text.RichText
                color: Kirigami.Theme.textColor
                font.bold: delegate.isHighlight && ThemeEngine.highlightIsBold
                font.pointSize: delegate.messagePointSize
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                Layout.fillWidth: true
                onLinkActivated: (link) => Qt.openUrlExternally(link)
            }
        }

        // ---------------------------------------------------------------- //
        // Bubble mode
        // ---------------------------------------------------------------- //
        RowLayout {
            id: bubbleRow
            visible: delegate.styleMode === 1
            Layout.fillWidth: true
            spacing: 0

            // Left spacer: only present for own messages, which pushes the
            // bubble to the right edge.
            Item {
                Layout.fillWidth: true
                visible: delegate.isSelf
            }

            Rectangle {
                id: bubble
                implicitWidth: bubbleContent.implicitWidth + delegate.hMargin * 2
                implicitHeight: bubbleContent.implicitHeight + delegate.hMargin * 2
                Layout.maximumWidth: delegate.width > 0 ? delegate.width * 0.8 : implicitWidth
                radius: ThemeEngine.bubbleRadius
                color: delegate.bubbleColor
                border.width: delegate.isHighlight ? 1 : 0
                border.color: Kirigami.Theme.highlightColor

                ColumnLayout {
                    id: bubbleContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: delegate.hMargin
                    spacing: Math.max(1, Math.round(Kirigami.Units.smallSpacing / 2))

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Controls.Label {
                            text: delegate.nick.length > 0 ? delegate.nick : qsTr("*")
                            color: delegate.visibleNickColor
                            font.bold: true
                            font.pointSize: delegate.messagePointSize
                            elide: Text.ElideRight
                        }

                        Controls.Label {
                            text: delegate.timestamp
                            color: Kirigami.Theme.disabledTextColor
                            font.pointSize: delegate.timestampPointSize
                            Layout.fillWidth: true
                            horizontalAlignment: delegate.isSelf ? Text.AlignRight : Text.AlignLeft
                        }
                    }

                    Kirigami.SelectableLabel {
                        id: bubbleText
                        text: ThemeEngine.formatMessage(delegate.text)
                        textFormat: Text.RichText
                        color: delegate.bubbleTextColor
                        font.bold: delegate.isHighlight && ThemeEngine.highlightIsBold
                        font.pointSize: delegate.messagePointSize
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        Layout.fillWidth: true
                        Layout.preferredWidth: Math.min(bubbleText.implicitWidth, delegate.maxTextWidth)
                        onLinkActivated: (link) => Qt.openUrlExternally(link)
                    }
                }
            }

            // Right spacer: pushes other people's bubbles to the left edge.
            Item {
                Layout.fillWidth: true
                visible: !delegate.isSelf
            }
        }
    }
}
