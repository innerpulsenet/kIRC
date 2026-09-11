// SPDX-License-Identifier: GPL-2.0-or-later
//
// MessageDelegate — one line of the IRC log.
//
// A pure, O(1) console/TUI renderer. No bubbles, no avatars, no grouping:
//
//     [17:41] patrickh  │ hello there
//     [17:41] * bob joined #pain              <- event rows: dim, no nick column
//     [17:41] patrickh  │ * waves             <- /me action (the core bakes "* ")
//     ───────── Today ──────────              <- day rule (showDay/dayLabel)
//
// Every row renders from the model roles ALONE — nick, text, timestamp,
// isSelf, isHighlight plus the model-computed isEvent, showDay and dayLabel.
// The delegate never scans the view for its own row, is never asked to look
// at another delegate, and holds no neighbour/grouping state, so creating a
// row costs the same whether the log holds ten rows or ten thousand.
// `showDay`/`dayLabel` are derived in Rust (rust/src/bridge.rs) when the row
// is produced.
//
// Layout is three fixed columns: the `[HH:MM]` time gutter (`gutterWidth`),
// the nick column padded to `nickColumn` characters, and the message body.
// The body is its own column, so a wrapped line's continuation starts at the
// text column (hanging indent), never back at column 0.
//
// Sizing: the root is an Item whose implicitHeight follows the day rule plus
// the console line plus the row gap, so the hosting ListView sizes rows with
// `spacing: 0`. `width` binds to the hosting ListView (falling back to
// implicit sizing when previewed standalone).
//
// There is deliberately NO hover handling: nothing may appear on hover that
// changes a row's height or shifts the text column.

import QtQuick
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
    required property string timestamp
    required property bool isSelf
    required property bool isHighlight
    // Model-computed presentation flags (rust/src/bridge.rs).
    required property bool isEvent
    required property bool showDay
    required property string dayLabel

    // --- theme (terminal tokens; see ThemeEngine) --------------------------
    readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
    readonly property string monoFamily: ThemeEngine.fontFamily
    // One size for the whole line: gutter, nick and body share the console
    // baseline (a monospace grid only lines up at one size).
    readonly property int bodyPointSize: ThemeEngine.resolvePointSize(ThemeEngine.messageSize, Kirigami.Theme.defaultFont.pointSize)

    readonly property color fgPrimaryColor: ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
    readonly property color fgDimColor: ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
    readonly property color fgAccentColor: ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor)
    readonly property color ruleColor: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)

    // Own lines reuse the accent so they stand out without any alignment
    // change; everybody else keeps their deterministic nick colour.
    readonly property color nickColor: delegate.isSelf
        ? delegate.fgAccentColor
        : ThemeEngine.nickColor(delegate.nick, delegate.darkTheme)

    // --- geometry ----------------------------------------------------------
    readonly property int inset: Math.round(Kirigami.Units.smallSpacing)

    // Monospace advance: every glyph (spaces included) is this wide, which is
    // what makes the padded nick column and the box-drawing rule align.
    FontMetrics {
        id: bodyMetrics
        font.family: delegate.monoFamily
        font.pointSize: delegate.bodyPointSize
    }
    readonly property real charWidth: bodyMetrics.averageCharacterWidth
    readonly property real spaceWidth: Math.max(1, delegate.charWidth)

    // Fixed pixel width of the "[HH:MM]" gutter: the theme token when set,
    // otherwise the fallback measured from the font.
    readonly property real gutterWidth: ThemeEngine.resolveGutterWidth(Math.ceil(delegate.charWidth * 8))
    // Width of the nick column in pixels (0 = no padding, natural width).
    readonly property real nickWidth: delegate.nickColumn > 0
        ? Math.ceil(delegate.charWidth * delegate.nickColumn)
        : 0

    readonly property int nickColumn: ThemeEngine.nickColumn

    // --- text content (bindings only — no view lookups, no neighbour work) --

    // "[17:41]" — the display stamp is preformatted by the bridge; "[--:--]"
    // is the defensive fallback for a row without one.
    readonly property string gutterLabel: "[" + (delegate.timestamp.length > 0 ? delegate.timestamp : "--:--") + "]"

    // The nick padded to `nickColumn` characters with spaces (0 = no padding).
    // A nick longer than the column is cut to the column width and marked with
    // a single trailing character, so the body column never shifts.
    readonly property string nickColumnText: {
        var col = delegate.nickColumn
        var n = delegate.nick
        if (col <= 0 || n.length === 0) {
            return n
        }
        if (n.length <= col) {
            return ThemeEngine.paddedNick(n)
        }
        return n.substring(0, col - 1) + "\u2026"
    }

    // Event rows are the synthesized channel lines (nick "*"): they render as
    // the classic muted "* nick did a thing" line. Everything else is a normal
    // message; a /me action arrives with the star already baked into `text`
    // ("* waves"), so it shares the normal line.
    readonly property string bodyText: delegate.isEvent
        ? "* " + delegate.text
        : delegate.text

    readonly property string bodyMarkup: ThemeEngine.formatMessage(
        delegate.bodyText,
        ThemeEngine.cssColor(ThemeEngine.linkColorValue(Kirigami.Theme.highlightColor)))

    // Day rule: "──────── Today ──────────", sized to the row width.
    readonly property string dayRuleText: {
        if (!delegate.showDay) {
            return ""
        }
        var label = delegate.dayLabel
        var inner = label.length > 0 ? (" " + label + " ") : ""
        var total = Math.max(6, Math.floor(delegate.width / delegate.spaceWidth))
        if (inner.length + 2 >= total) {
            return label
        }
        var left = Math.floor((total - inner.length) / 2)
        var right = total - inner.length - left
        return "\u2500".repeat(left) + inner + "\u2500".repeat(right)
    }

    width: {
        var view = ListView.view
        if (!view) {
            return implicitWidth
        }
        // ListView.view.width is the viewport, not the content item — left/right
        // margins would otherwise be painted over.
        return Math.max(0, view.width - view.leftMargin - view.rightMargin)
    }
    // Deliberately not derived from the (width-dependent) day rule: that would
    // bind implicitWidth to width when previewed standalone.
    implicitWidth: line.implicitWidth
    implicitHeight: dayRule.height + line.implicitHeight + delegate.rowGap

    readonly property real rowGap: Math.max(0, Math.round(ThemeEngine.denseLineSpacing))

    // ---------------------------------------------------------------------- //
    // Day rule: a box-drawing section marker. Always present with an explicit
    // height (0 when the row does not start a day section), so nothing reflows.
    // The height reads the child Text's implicitHeight (a different object —
    // binding `height` to the Text's OWN implicitHeight is a binding loop).
    // ---------------------------------------------------------------------- //
    Item {
        id: dayRule
        anchors.left: parent.left
        anchors.leftMargin: delegate.inset
        width: Math.max(0, delegate.width - delegate.inset * 2)
        height: delegate.showDay ? ruleText.implicitHeight : 0
        clip: true

        Text {
            id: ruleText
            width: parent.width
            text: delegate.dayRuleText
            color: delegate.ruleColor
            font.family: delegate.monoFamily
            font.pointSize: delegate.bodyPointSize
            wrapMode: Text.NoWrap
            clip: true
        }
    }

    // ---------------------------------------------------------------------- //
    // The console line: [gutter] [nick] │ [message]
    // ---------------------------------------------------------------------- //
    RowLayout {
        id: line
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: dayRule.bottom
        anchors.leftMargin: delegate.inset
        anchors.rightMargin: delegate.inset
        spacing: delegate.spaceWidth

        // Fixed-width time gutter.
        Text {
            Layout.preferredWidth: delegate.gutterWidth
            Layout.alignment: Qt.AlignTop
            text: delegate.gutterLabel
            color: delegate.fgDimColor
            font.family: delegate.monoFamily
            font.pointSize: delegate.bodyPointSize
            wrapMode: Text.NoWrap
        }

        // Nick column: padded with spaces to `nickColumn` characters (0 = no
        // padding, the nick takes its natural width). Hidden for event rows,
        // which carry no nick column at all.
        Text {
            id: nickText
            visible: !delegate.isEvent
            Layout.preferredWidth: delegate.nickWidth > 0 ? delegate.nickWidth : implicitWidth
            Layout.alignment: Qt.AlignTop
            text: delegate.nickColumnText
            color: delegate.nickColor
            font.family: delegate.monoFamily
            font.pointSize: delegate.bodyPointSize
            wrapMode: Text.NoWrap
        }

        // Column separator between the nick column and the body.
        Text {
            visible: !delegate.isEvent
            Layout.alignment: Qt.AlignTop
            text: "\u2502"
            color: delegate.ruleColor
            font.family: delegate.monoFamily
            font.pointSize: delegate.bodyPointSize
            wrapMode: Text.NoWrap
        }

        // Message body. Its own column is what gives wrapped lines their
        // hanging indent: the continuation starts where the body starts.
        Text {
            id: body
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            text: delegate.bodyMarkup
            textFormat: Text.RichText
            color: delegate.isEvent ? delegate.fgDimColor : delegate.fgPrimaryColor
            font.family: delegate.monoFamily
            font.pointSize: delegate.bodyPointSize
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            onLinkActivated: (link) => Qt.openUrlExternally(link)
        }
    }

    // ---------------------------------------------------------------------- //
    // Highlight: an accent marker bar in the page margin (no rounded band, no
    // background wash — the row keeps every other row's geometry).
    // ---------------------------------------------------------------------- //
    Rectangle {
        anchors.left: parent.left
        anchors.top: line.top
        width: 3
        height: line.height
        visible: delegate.isHighlight && !delegate.isEvent
        color: delegate.fgAccentColor
        radius: 0
    }
}
