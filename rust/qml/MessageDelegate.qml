// SPDX-License-Identifier: GPL-2.0-or-later
//
// MessageDelegate — one IRC message.
//
// Two rendering modes, driven by `styleMode` (which ChatPage derives from
// ThemeEngine.mode):
//   0 = dense  : compact "<time> <nick>: text" IRC line (avatar-free)
//   1 = bubble : modern chat look — nick-coloured avatar circle, sender name,
//                rounded bubble, own messages right-aligned in the accent
//                colour, consecutive messages from one sender merged into a
//                group (avatar/name once, tighter spacing, joined corners).
//
// Grouping is computed imperatively (never per frame): the delegate asks the
// ListView for its neighbours once it is created and whenever its index
// changes, and nudges its neighbours to re-evaluate when it appears. Only the
// preformatted "HH:MM" timestamp is available, so a group is "same sender, no
// more than ThemeEngine.groupingWindowMinutes apart"; anything unparseable is
// deliberately *not* grouped.
//
// Sizing: the root is an Item whose implicitHeight follows the content row plus
// the gap to the next message (groups are tightened), so ListView sizes rows
// correctly with `spacing: 0`. `width` binds to the hosting ListView (falling
// back to implicit sizing when previewed standalone).

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

pragma ComponentBehavior: Bound

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

    // Gaps to the previous/next message are set by recomputeGrouping().
    property bool continuesPrevious: false
    property bool continuesNext: false

    readonly property bool hovered: hoverHandler.hovered

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
    readonly property int timestampPointSize: ThemeEngine.resolvePointSize(ThemeEngine.timestampSize, Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1))
    readonly property int nickPointSize: ThemeEngine.resolvePointSize(ThemeEngine.nickSize, delegate.messagePointSize)

    // --- geometry ----------------------------------------------------------
    readonly property int hMargin: Kirigami.Units.largeSpacing
    readonly property int avatarPx: ThemeEngine.avatarSizeFor(Kirigami.Units.gridUnit)
    readonly property int avatarGutter: delegate.avatarPx + Kirigami.Units.smallSpacing
    readonly property bool avatarVisible: ThemeEngine.avatarEnabled && delegate.styleMode === 1
    // Server notices arrive with a decorative nick ("*" or empty). They get the
    // avatar gutter but no bubble-with-a-letter, so console traffic reads as
    // system output instead of messages from a user called "?".
    readonly property bool decorativeNick: delegate.nick.trim().length === 0 || delegate.nick.trim() === "*"
    readonly property int bubblePaddingH: Math.round(Kirigami.Units.gridUnit * 0.5)
    readonly property int bubblePaddingV: Math.round(Kirigami.Units.gridUnit * 0.33)
    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.10)
    readonly property color highlightWash: ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.18)

    // Widest a wrapped bubble may get, avatar column included.
    readonly property real maxBubbleWidth: Math.max(
        Kirigami.Units.gridUnit * 6,
        delegate.width * ThemeEngine.bubbleMaxWidthFraction
            - (delegate.avatarVisible ? delegate.avatarGutter : 0)
            - delegate.hMargin
    )

    // Widest the text itself may get inside a bubble.
    readonly property real maxTextWidth: Math.max(
        Kirigami.Units.gridUnit * 4,
        delegate.maxBubbleWidth - delegate.bubblePaddingH * 2
    )

    // Bubble width comes from measuring the *unwrapped* message: a TextEdit
    // (which is what SelectableLabel wraps) reports a contentWidth that follows
    // its current width, so sizing the bubble from it collapses the bubble to
    // one character per line. A hidden Text is used rather than TextMetrics
    // because it runs the same (hinted) text layout the label does, so the
    // measured width really is the width at which the text stops wrapping.
    Text {
        id: messageMeasure
        visible: false
        text: delegate.text
        font: bubbleText.font
        wrapMode: Text.NoWrap
    }

    readonly property real naturalTextWidth: Math.min(delegate.maxTextWidth, Math.ceil(messageMeasure.implicitWidth))

    // Bubble corner radii: the corner facing the neighbouring message of the
    // same group is flattened so the bubbles read as one connected block.
    readonly property real radiusTL: (delegate.continuesPrevious && !delegate.isSelf) ? ThemeEngine.bubbleTailRadius : ThemeEngine.bubbleRadius
    readonly property real radiusTR: (delegate.continuesPrevious && delegate.isSelf) ? ThemeEngine.bubbleTailRadius : ThemeEngine.bubbleRadius
    readonly property real radiusBL: (delegate.continuesNext && !delegate.isSelf) ? ThemeEngine.bubbleTailRadius : ThemeEngine.bubbleRadius
    readonly property real radiusBR: (delegate.continuesNext && delegate.isSelf) ? ThemeEngine.bubbleTailRadius : ThemeEngine.bubbleRadius

    readonly property int rowGap: delegate.styleMode === 1
        ? (delegate.continuesNext ? ThemeEngine.bubbleGroupSpacing : ThemeEngine.bubbleSpacing)
        : (delegate.continuesNext ? ThemeEngine.denseLineSpacing
                                  : ThemeEngine.denseLineSpacing * 3)

    // Links follow the accent colour; on own (accent-filled) bubbles they
    // keep the bubble's own text colour so they stay readable.
    readonly property string linkCss: ThemeEngine.cssColor(
        delegate.isSelf ? delegate.bubbleTextColor
                        : ThemeEngine.linkColorValue(Kirigami.Theme.highlightColor))

    width: {
        var view = ListView.view
        if (!view) {
            return implicitWidth
        }
        // ListView.view.width is the viewport, not the content item — left/right
        // margins would otherwise be painted over (self avatars sat in the
        // overlay scrollbar gutter).
        return Math.max(0, view.width - view.leftMargin - view.rightMargin)
    }
    implicitWidth: Math.max(bubbleRow.implicitWidth, denseRow.implicitWidth)
    implicitHeight: (delegate.styleMode === 1 ? bubbleRow.implicitHeight : denseRow.implicitHeight) + delegate.rowGap

    HoverHandler {
        id: hoverHandler
    }

    // ---------------------------------------------------------------------- //
    // Grouping
    // ---------------------------------------------------------------------- //

    /// Position of this delegate in its view.
    ///
    /// The view's `index` is NOT readable through the delegate object on Qt 6.11
    /// (a `required property int index` stays undefined both inside and outside
    /// the delegate), so the position is resolved by identity instead. The view
    /// only ever holds the visible rows plus its cache buffer, so the scan stays
    /// small, and it runs once per delegate (not per frame).
    function viewIndex()
    {
        var view = ListView.view
        if (!view) {
            return -1
        }
        for (var i = 0; i < view.count; ++i) {
            if (view.itemAtIndex(i) === delegate) {
                return i
            }
        }
        return -1
    }

    /// Delegate sitting at `index`, or null when that row is not instantiated.
    /// The grouping helpers cope with a half-initialised delegate (their role
    /// guards treat missing values as "not the same sender"), so this does not
    /// touch the neighbour's properties at all — which also keeps `qmllint`
    /// quiet about `itemAtIndex()` returning a plain QQuickItem.
    function neighbourAt(index)
    {
        var view = ListView.view
        if (!view || index < 0 || index >= view.count) {
            return null
        }
        return view.itemAtIndex(index)
    }

    /// Does `item` (the row before this one) continue into this message?
    function continuesFrom(item)
    {
        return item !== null && ThemeEngine.grouped(item, delegate)
    }

    /// Does this message continue into `item` (the row after it)?
    function continuesInto(item)
    {
        return item !== null && ThemeEngine.grouped(delegate, item)
    }

    function recomputeGrouping()
    {
        var self = delegate.viewIndex()
        if (self < 0) {
            // Not laid out (or parked in the reuse pool): no group edges.
            delegate.continuesPrevious = false
            delegate.continuesNext = false
            return
        }
        delegate.continuesPrevious = delegate.continuesFrom(delegate.neighbourAt(self - 1))
        delegate.continuesNext = delegate.continuesInto(delegate.neighbourAt(self + 1))
    }

    /// Our own edges depend on the neighbours and theirs on us, so whoever
    /// (re)appears asks both neighbours to look again.
    function refreshNeighbours()
    {
        var self = delegate.viewIndex()
        if (self < 0) {
            return
        }
        var previous = delegate.neighbourAt(self - 1)
        if (previous && previous.recomputeGrouping) {
            previous.recomputeGrouping()
        }
        var next = delegate.neighbourAt(self + 1)
        if (next && next.recomputeGrouping) {
            next.recomputeGrouping()
        }
    }

    function settle()
    {
        delegate.recomputeGrouping()
        delegate.refreshNeighbours()
    }

    Component.onCompleted: Qt.callLater(delegate.settle)

    // Required properties cannot carry a change handler, so recycling is
    // caught through the roles instead: a delegate reused for another row gets
    // new nick/timestamp/isSelf values, which re-runs the grouping.
    onNickChanged: Qt.callLater(delegate.settle)
    onTimestampChanged: Qt.callLater(delegate.settle)
    onIsSelfChanged: Qt.callLater(delegate.settle)
    onTextChanged: Qt.callLater(delegate.refreshNeighbours)

    // ---------------------------------------------------------------------- //
    // Highlight marker: a slim accent bar in the page margin.
    // ---------------------------------------------------------------------- //
    Rectangle {
        id: stripe
        visible: delegate.isHighlight
        anchors.left: parent.left
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.bottomMargin: delegate.rowGap
        width: 3
        radius: width / 2
        color: Kirigami.Theme.highlightColor
    }

    // ---------------------------------------------------------------------- //
    // Dense IRC line
    // ---------------------------------------------------------------------- //
    RowLayout {
        id: denseRow
        visible: delegate.styleMode === 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: delegate.hMargin
        anchors.rightMargin: delegate.hMargin
        spacing: Kirigami.Units.smallSpacing

        Controls.Label {
            text: delegate.timestamp
            color: Kirigami.Theme.disabledTextColor
            font.pointSize: delegate.timestampPointSize
            opacity: delegate.continuesPrevious ? 0 : 1
            Layout.alignment: Qt.AlignTop
        }

        Controls.Label {
            text: (delegate.nick.length > 0 ? delegate.nick : qsTr("*")) + ":"
            color: delegate.visibleNickColor
            font.bold: true
            font.pointSize: delegate.nickPointSize
            Layout.alignment: Qt.AlignTop
        }

        // TODO(code-highlight): syntax-highlight fenced code blocks (needs a
        // KSyntaxHighlighting bridge on the C++ side; out of scope for pass 1).
        Kirigami.SelectableLabel {
            id: denseText
            text: ThemeEngine.formatMessage(delegate.text, delegate.linkCss)
            textFormat: Text.RichText
            color: Kirigami.Theme.textColor
            font.bold: delegate.isHighlight && ThemeEngine.highlightIsBold
            font.pointSize: delegate.messagePointSize
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            Layout.fillWidth: true
            // The style's default padding is subtracted from the text area, so
            // the measured width would not match the space the text really gets.
            padding: 0
            onLinkActivated: (link) => Qt.openUrlExternally(link)
        }
    }

    // ---------------------------------------------------------------------- //
    // Bubble mode (default)
    // ---------------------------------------------------------------------- //
    RowLayout {
        id: bubbleRow
        visible: delegate.styleMode === 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: delegate.hMargin
        anchors.rightMargin: delegate.hMargin
        spacing: Kirigami.Units.smallSpacing

        // Avatar (other people) — reserved even when grouped, so every bubble
        // in a group lines up.
        Item {
            visible: !delegate.isSelf
            Layout.preferredWidth: delegate.avatarVisible ? delegate.avatarGutter : 0
            Layout.preferredHeight: delegate.avatarVisible ? delegate.avatarPx : 0
            Layout.alignment: Qt.AlignTop

            Rectangle {
                visible: delegate.avatarVisible && !delegate.continuesPrevious && !delegate.decorativeNick
                width: delegate.avatarPx
                height: delegate.avatarPx
                radius: Math.min(width, height) / 2
                color: delegate.nickColorValue

                Controls.Label {
                    anchors.centerIn: parent
                    text: ThemeEngine.initial(delegate.nick)
                    color: ThemeEngine.contrastingTextColor(delegate.nickColorValue)
                    font.bold: true
                    font.pointSize: Math.max(1, delegate.messagePointSize)
                }
            }
        }

        Item {
            visible: delegate.isSelf
            Layout.fillWidth: true
        }

        // ---- bubble ----
        Rectangle {
            id: bubble
            Layout.alignment: Qt.AlignTop
            Layout.maximumWidth: delegate.maxBubbleWidth
            implicitWidth: Math.min(
                delegate.maxBubbleWidth,
                Math.max(delegate.naturalTextWidth, nameRow.implicitWidth) + delegate.bubblePaddingH * 2
            )
            implicitHeight: bubbleContent.implicitHeight + delegate.bubblePaddingV * 2
            radius: delegate.isSelf ? delegate.radiusTR : delegate.radiusTL
            topLeftRadius: delegate.radiusTL
            topRightRadius: delegate.radiusTR
            bottomLeftRadius: delegate.radiusBL
            bottomRightRadius: delegate.radiusBR
            color: delegate.bubbleColor
            // Highlighted lines are marked by the accent bar in the page margin
            // plus the tinted fill below — no extra outline, which only made the
            // bubble look busy.
            border.width: 0

            // Accent wash for highlighted lines, clipped to the bubble shape.
            Rectangle {
                anchors.fill: parent
                visible: delegate.isHighlight
                radius: parent.radius
                topLeftRadius: parent.topLeftRadius
                topRightRadius: parent.topRightRadius
                bottomLeftRadius: parent.bottomLeftRadius
                bottomRightRadius: parent.bottomRightRadius
                color: delegate.highlightWash
            }

            ColumnLayout {
                id: bubbleContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: delegate.bubblePaddingH
                anchors.topMargin: delegate.bubblePaddingV
                anchors.bottomMargin: delegate.bubblePaddingV
                spacing: Math.max(2, Math.round(Kirigami.Units.smallSpacing / 2))

                // Sender name — once per group, never for own messages. The
                // timestamp always lives in the block below, so it never moves
                // around the bubble between grouped and ungrouped messages.
                RowLayout {
                    id: nameRow
                    visible: !delegate.isSelf && !delegate.continuesPrevious
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        text: delegate.nick.length > 0 ? delegate.nick : qsTr("*")
                        color: delegate.visibleNickColor
                        font.bold: true
                        font.pointSize: delegate.nickPointSize
                        elide: Text.ElideRight
                        Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 4,
                                                      delegate.maxBubbleWidth - delegate.bubblePaddingH * 2 - Kirigami.Units.gridUnit * 3)
                    }

                    Item { Layout.fillWidth: true }
                }

                Kirigami.SelectableLabel {
                    id: bubbleText
                    text: ThemeEngine.formatMessage(delegate.text, delegate.linkCss)
                    textFormat: Text.RichText
                    color: delegate.bubbleTextColor
                    font.bold: delegate.isHighlight && ThemeEngine.highlightIsBold
                    font.pointSize: delegate.messagePointSize
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    Layout.fillWidth: true
                    // See the dense label: keep the text area == the bubble's.
                    padding: 0
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                }

                // Timestamp only on the last bubble of a group. Never on hover:
                // toggling visibility changes implicitHeight and makes the
                // whole log jump when the pointer moves.
                RowLayout {
                    visible: !delegate.continuesNext
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Item { Layout.fillWidth: true }

                    Controls.Label {
                        text: delegate.timestamp
                        color: Kirigami.Theme.disabledTextColor
                        font.pointSize: delegate.timestampPointSize
                    }
                }
            }
        }

        Item {
            visible: !delegate.isSelf
            Layout.fillWidth: true
        }

        // Avatar (own messages) — right-hand side, matching the left column.
        Item {
            visible: delegate.isSelf
            Layout.preferredWidth: delegate.avatarVisible ? delegate.avatarGutter : 0
            Layout.preferredHeight: delegate.avatarVisible ? delegate.avatarPx : 0
            Layout.alignment: Qt.AlignTop

            Rectangle {
                anchors.right: parent.right
                visible: delegate.avatarVisible && !delegate.continuesPrevious && !delegate.decorativeNick
                width: delegate.avatarPx
                height: delegate.avatarPx
                radius: Math.min(width, height) / 2
                color: delegate.nickColorValue

                Controls.Label {
                    anchors.centerIn: parent
                    text: ThemeEngine.initial(delegate.nick)
                    color: ThemeEngine.contrastingTextColor(delegate.nickColorValue)
                    font.bold: true
                    font.pointSize: Math.max(1, delegate.messagePointSize)
                }
            }
        }
    }
}
