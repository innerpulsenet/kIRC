// SPDX-License-Identifier: GPL-2.0-or-later
//
// SettingsPage — two-pane terminal-style settings surface.
//
//   ┌ kirc settings ─────────────────────────────┐  search box
//   ├ ▌ identity      │ ── Nickname ──────────── │
//   │   connection    │  [ yournick          ]  │
//   │   appearance    │ ── NickServ account ─── │
//   │   notifications │  [ account           ]  │
//   │   about         │                          │
//
// Left: a compact monospace navigation list (Identity / Connection /
// Appearance / Notifications / About); the active row is inverse video.
// Right: the selected section's rows, flat labelled rows separated by
// box-drawing rules. No rounded cards, no oversized controls, everything
// left-aligned in one label column so labels and controls line up.
//
// Behaviour is unchanged from the previous rebuild:
//   * live search filters rows across sections (sections with matches are
//     marked in the navigation, sections without are dimmed, and the pane
//     follows the first section that matches),
//   * every control persists through KircConfig (cpp/kircconfig.h),
//   * a password is never written to kirc.conf: the NickServ *and* server
//     (PASS) passwords go to KWallet via KircConfig, the SASL password is
//     session only and is not editable here.
//
// Rows beyond the original rebuild: server password (Connection), on-join
// history limit (`historyLimit`, 0 = off) and the default part/quit reason
// (`defaultPartReason`, consumed by ChatPage when /part or /quit has no
// reason of its own).

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirc

// Delegates (navigation rows, theme rows, autojoin rows) reference the page's
// functions and properties; bound component behaviour resolves those
// statically instead of through the dynamic context, and keeps qmllint clean.
pragma ComponentBehavior: Bound

Kirigami.Page {
    id: page

    property var kircConfig: null
    // The application window (set by main.qml).  Replaces the deprecated
    // `applicationWindow()` global: it keeps qmllint clean and, more
    // importantly, keeps the SASL-user save working if the global is removed
    // in a future Qt.  Null in standalone harnesses.
    property var hostWindow: null
    // Lets the window find an already-open instance (openSettings/openAbout).
    readonly property bool isKircSettingsPage: true

    title: qsTr("Settings")
    // The terminal surface owns its own margins: no page padding, no cards.
    padding: 0

    // Page surface: the theme's log colour (empty token = the desktop
    // background, so `breeze` still follows the user's scheme).
    background: Rectangle {
        color: page.bgLogC()
    }

    // ---------------------------------------------------------------------- //
    // Navigation + search state
    // ---------------------------------------------------------------------- //
    // 0 = identity, 1 = connection, 2 = appearance, 3 = notifications, 4 = about
    property int sectionIndex: 0

    // Live search text; each row binds its visibility to it.
    property string filter: ""

    // Compatibility shim: main.qml's openAbout() used to scroll to a card.
    // In the two-pane layout "About" is simply the selected section.
    property var aboutCard: null

    readonly property var sectionIds: ["identity", "connection", "appearance", "notifications", "about"]

    // Search keywords per section, and the row labels each section contains
    // (used by the live filter).
    readonly property var sectionKeywords: [
        ["identity", "nickname", "nickserv", "account", "password", "sasl", "mechanism", "user", "plain", "external", "auto"],
        ["connection", "autojoin", "channel", "password", "server", "pass", "history", "lines", "scrollback", "reconnect", "retry", "authentication", "identify", "part", "quit", "reason", "leave", "ctcp", "version", "client", "reply", "privacy"],
        ["appearance", "theme", "font", "size", "timestamps", "colour", "color", "palette"],
        ["notifications", "notification", "highlight", "direct message", "tray", "minimize"],
        ["about", "version", "kirc", "license", "kde", "passwords"]
    ]
    readonly property var sectionRowLabels: [
        ["Nickname", "NickServ account", "NickServ password", "SASL user", "SASL mechanism"],
        ["Server password", "Identify", "CTCP version", "Autojoin", "History", "Reconnect", "Retry limit", "Auth failures", "Part reason"],
        ["Theme", "Font family", "Font size", "Timestamps"],
        ["Highlights", "Direct messages", "System tray"],
        ["Version", "Passwords"]
    ]

    function sectionName(i)
    {
        switch (i) {
        case 0: return qsTr("Identity")
        case 1: return qsTr("Connection")
        case 2: return qsTr("Appearance")
        case 3: return qsTr("Notifications")
        case 4: return qsTr("About")
        }
        return ""
    }

    function matches(haystack, needle)
    {
        return haystack.toLowerCase().indexOf(needle) >= 0
    }

    /// Number of rows in section `i` that match the live filter.
    function sectionMatchCount(i)
    {
        if (page.filter.length === 0) {
            return page.sectionRowLabels[i].length
        }
        var rows = page.sectionRowLabels[i]
        var n = 0
        for (var r = 0; r < rows.length; ++r) {
            if (page.matches(rows[r], page.filter)) {
                ++n
            }
        }
        return n
    }

    /// True when the section has a match (or no filter is active).
    function sectionMatches(i)
    {
        if (page.filter.length === 0) {
            return true
        }
        if (page.sectionMatchCount(i) > 0) {
            return true
        }
        var words = page.sectionKeywords[i]
        for (var k = 0; k < words.length; ++k) {
            if (page.matches(words[k], page.filter)) {
                return true
            }
        }
        return false
    }

    function anyMatch()
    {
        for (var i = 0; i < page.sectionIds.length; ++i) {
            if (page.sectionMatches(i)) {
                return true
            }
        }
        return false
    }

    /// A single row is visible when it matches the filter.
    function rowVisible(label)
    {
        return page.filter.length === 0 || page.matches(label, page.filter)
    }

    /// Filtering rows across sections: apply the text, and keep the pane on a
    /// section that actually has matches.
    function setFilter(text)
    {
        page.filter = String(text === undefined || text === null ? "" : text).trim()
        if (page.filter.length === 0) {
            return
        }
        if (page.sectionIndex < page.sectionIds.length && page.sectionMatches(page.sectionIndex)) {
            return
        }
        for (var i = 0; i < page.sectionIds.length; ++i) {
            if (page.sectionMatches(i)) {
                page.sectionIndex = i
                return
            }
        }
    }

    function selectSection(i)
    {
        if (i >= 0 && i < page.sectionIds.length) {
            page.sectionIndex = i
        }
    }

    // main.qml (openAbout) selects the About section.
    function showAbout()
    {
        page.selectSection(4)
    }

    // ---------------------------------------------------------------------- //
    // Type scale + terminal colours (theme tokens with Kirigami fallbacks)
    // ---------------------------------------------------------------------- //
    readonly property string mono: ThemeEngine.fontFamily
    readonly property int pt: Math.max(7, Kirigami.Theme.defaultFont.pointSize)
    readonly property int ptSmall: Math.max(7, page.pt - 1)
    readonly property int labelCol: Math.round(Kirigami.Units.gridUnit * 8)
    readonly property int rowPad: 8

    function fgMain() { return ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor) }
    function fgDim() { return ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor) }
    function fgAccent() { return ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor) }
    function fgWarn() { return ThemeEngine.fgWarnColor(Kirigami.Theme.negativeTextColor) }
    function bgLogC() { return ThemeEngine.bgLogColor(Kirigami.Theme.backgroundColor) }
    function bgPanelC() { return ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor) }
    function bgInputC() { return ThemeEngine.bgInputColor(Kirigami.Theme.alternateBackgroundColor) }
    function ruleC() { return ThemeEngine.ruleColorValue(ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.20)) }
    function accentTextC() { return ThemeEngine.accentTextColor(Kirigami.Theme.highlightedTextColor) }
    function hoverC() { return ThemeEngine.rowHoverColor(ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.07)) }
    function selC() { return ThemeEngine.rowSelectedColor(ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.20)) }

    /// "── Identity " + a one-pixel rule that fills the rest of the row.
    component SectionHeader: RowLayout {
        id: sectionHeader

        property string title: ""

        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.topMargin: 10
        Layout.bottomMargin: 6
        spacing: 0

        Text {
            text: "── " + sectionHeader.title + " "
            color: page.fgAccent()
            font.family: page.mono
            font.pointSize: page.ptSmall
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: 1
            color: page.ruleC()
        }
    }

    // ---------------------------------------------------------------------- //
    // Inline components — flat, monospace, square. (A nested Repeater inside a
    // control's custom contentItem SIGSEGVs Qt 6.11; these components keep the
    // contentItems plain.)
    // ---------------------------------------------------------------------- //

    /// Flat labelled row: the label sits in a fixed monospace column so every
    /// control in the pane starts at the same x.
    component TermRow: RowLayout {
        id: termRow

        property string label: ""

        Layout.fillWidth: true
        Layout.topMargin: 5
        Layout.bottomMargin: 5
        spacing: 8

        Text {
            Layout.preferredWidth: page.labelCol
            Layout.alignment: Qt.AlignVCenter
            text: termRow.label
            color: page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
            elide: Text.ElideRight
        }
    }

    /// One-pixel box-drawing rule between rows.
    component TermRule: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: page.ruleC()
    }

    /// Flat square text field on the input surface.
    component TermField: Controls.TextField {
        id: termField

        Layout.fillWidth: true
        font.family: page.mono
        font.pointSize: page.ptSmall
        color: page.fgMain()
        placeholderTextColor: page.fgDim()
        selectionColor: page.fgAccent()
        selectedTextColor: page.bgLogC()
        leftPadding: 6
        rightPadding: 6

        background: Rectangle {
            implicitWidth: 100
            implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
            radius: 0
            color: page.bgInputC()
            border.width: 1
            border.color: termField.activeFocus ? page.fgAccent() : page.ruleC()
        }
    }

    /// Terminal checkbox: [x] / [ ] drawn in monospace.
    component TermToggle: Controls.CheckBox {
        id: termToggle

        Layout.fillWidth: true
        font.family: page.mono
        font.pointSize: page.ptSmall
        spacing: 8
        rightPadding: 0

        indicator: Text {
            x: termToggle.leftPadding
            y: termToggle.topPadding + (termToggle.availableHeight - height) / 2
            text: termToggle.checked ? "[x]" : "[ ]"
            color: termToggle.checked ? page.fgAccent() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
        }

        contentItem: Text {
            leftPadding: termToggle.leftPadding + termToggle.indicator.width + termToggle.spacing
            text: termToggle.text
            color: termToggle.enabled ? page.fgMain() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    /// Flat square button ("[add]", "[show]"…).
    component TermButton: Controls.Button {
        id: termButton

        property string prompt: ""

        font.family: page.mono
        font.pointSize: page.ptSmall
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
        implicitWidth: contentItem.implicitWidth + 16
        text: termButton.prompt

        background: Rectangle {
            radius: 0
            color: termButton.down ? page.selC() : (termButton.hovered ? page.hoverC() : page.bgInputC())
            border.width: 1
            border.color: termButton.enabled ? page.ruleC() : page.bgInputC()
        }

        contentItem: Text {
            text: termButton.text
            color: termButton.enabled ? page.fgMain() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    /// Flat square combo box.  The text and the arrow are drawn inside the flat
    /// background on purpose: the desktop style draws a non-editable combo's
    /// text in its StyleItem background, and its contentItem (an invisible
    /// TextField) is what the style's mobile-cursor binding targets — replacing
    /// either used to log a TypeError and hide the selected text.
    component TermCombo: Controls.ComboBox {
        id: termCombo

        font.family: page.mono
        font.pointSize: page.ptSmall
        implicitWidth: Math.round(Kirigami.Units.gridUnit * 11)

        background: Rectangle {
            implicitWidth: 80
            implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
            radius: 0
            color: page.bgInputC()
            border.width: 1
            border.color: (termCombo.activeFocus || termCombo.popup.visible) ? page.fgAccent() : page.ruleC()

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 6
                anchors.right: comboArrow.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: termCombo.displayText
                color: page.fgMain()
                font.family: page.mono
                font.pointSize: page.ptSmall
                elide: Text.ElideRight
            }

            Text {
                id: comboArrow
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: "▾"
                color: page.fgDim()
                font.family: page.mono
                font.pointSize: page.ptSmall
            }
        }

        delegate: Controls.ItemDelegate {
            id: termComboItem

            required property var modelData
            required property int index

            width: termCombo.width
            highlighted: termCombo.highlightedIndex === termComboItem.index

            contentItem: Text {
                leftPadding: 6
                text: (termComboItem.modelData === undefined || termComboItem.modelData === null)
                      ? "" : String(termComboItem.modelData)
                color: page.fgMain()
                font.family: page.mono
                font.pointSize: page.ptSmall
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            background: Rectangle {
                radius: 0
                color: termComboItem.highlighted ? page.selC() : page.bgInputC()
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // Configuration plumbing (unchanged contract)
    // ---------------------------------------------------------------------- //

    function cfg()
    {
        return page.kircConfig
    }

    function hasPref(name)
    {
        var c = page.cfg()
        return c !== null && c !== undefined && c[name] !== undefined
    }

    function persist()
    {
        var c = page.cfg()
        if (c === null || c === undefined) {
            return
        }
        c.themeId = ThemeEngine.themeId
        c.fontDelta = ThemeEngine.fontDelta
        if (page.hasPref("fontFamily")) {
            c.fontFamily = ThemeEngine.fontFamilyOverride
        }
        c.autojoin = autojoinModel.join(", ")
        c.reconnect = reconnectSwitch.checked
        c.minimizeToTray = traySwitch.checked
        c.identifyOnConnect = identifySwitch.checked
        c.nickservNick = nickservNickField.text
        // Password first: KWallet write, never kirc.conf (see KircConfig).
        c.nickservPassword = nickservPassField.text
        if (page.hasPref("saslMechanism")) {
            c.saslMechanism = page.saslMechanismId(saslMechBox.currentIndex)
        }
        if (page.hasPref("notifyHighlights")) {
            c.notifyHighlights = highlightSwitch.checked
            c.notifyDirectMessages = dmSwitch.checked
        }
        if (page.hasPref("reconnectLimit")) {
            c.reconnectLimit = parseInt(retryField.text, 10) || 0
            c.reconnectAfterAuthFailure = authRetrySwitch.checked
        }
        if (page.hasPref("historyLimit")) {
            c.historyLimit = parseInt(historyLimitField.text, 10) || 0
        }
        if (page.hasPref("defaultPartReason")) {
            c.defaultPartReason = defaultPartReasonField.text
        }
        if (page.hasPref("respondToCtcpVersion")) {
            c.respondToCtcpVersion = ctcpVersionSwitch.checked
        }
        // The server password is a secret like the others: it goes to KWallet
        // through KircConfig.save(), never into kirc.conf.
        c.serverPassword = serverPassField.text
        if (page.hasPref("showTimestamps")) {
            c.showTimestamps = timestampsSwitch.checked
        }
        c.save()
    }

    /// Apply a built-in theme and persist the pick.  ThemeEngine is a
    /// singleton every surface binds to, so the switch is live.  An unknown id
    /// leaves the active theme untouched (never persist a dead id).
    function selectTheme(id)
    {
        if (ThemeEngine.applyBuiltinTheme(id) !== "") {
            return
        }
        page.persist()
    }

    // --- SASL mechanism mapping (combo index <-> bridge/config id) ---------
    // Ids: 0 = Auto, 1 = PLAIN, 2 = EXTERNAL.  Kept in sync with
    // IrcBridge::set_sasl_mechanism and KircConfig.saslMechanism.
    function saslMechanismIndex(id)
    {
        return (id >= 0 && id <= 2) ? id : 0
    }

    function saslMechanismId(index)
    {
        return (index >= 0 && index <= 2) ? index : 0
    }

    function saslMechanismLabel(index)
    {
        switch (index) {
        case 1: return qsTr("PLAIN")
        case 2: return qsTr("EXTERNAL")
        }
        return qsTr("Auto")
    }

    // --- autojoin list model (comma-separated string <-> add/remove list) --
    property var autojoinModel: []

    function parseAutojoin(raw)
    {
        var out = []
        var seen = {}
        var parts = String(raw === undefined || raw === null ? "" : raw).split(/[\s,]+/)
        for (var i = 0; i < parts.length; ++i) {
            var ch = parts[i].trim()
            if (ch.length === 0) {
                continue
            }
            var key = ch.toLowerCase()
            if (!seen[key]) {
                seen[key] = true
                out.push(ch)
            }
        }
        return out
    }

    // --- font family list (monospace) --------------------------------------
    readonly property var fontFamilies: ThemeEngine.monospaceFamilies()

    Component.onCompleted: {
        // Restore the persisted font family (cpp/main.cpp also applies it at
        // startup; this covers harnesses and keeps the page self-consistent).
        if (page.hasPref("fontFamily") && page.cfg().fontFamily !== undefined) {
            ThemeEngine.fontFamilyOverride = page.cfg().fontFamily
        }

        var c = page.cfg()
        if (c !== null && c !== undefined) {
            page.autojoinModel = page.parseAutojoin(c.autojoin)
            reconnectSwitch.checked = c.reconnect
            traySwitch.checked = c.minimizeToTray
            fontSlider.value = c.fontDelta
            identifySwitch.checked = c.identifyOnConnect
            nickservNickField.text = c.nickservNick
            nickservPassField.text = c.nickservPassword
            if (page.hasPref("saslMechanism")) {
                saslMechBox.currentIndex = page.saslMechanismIndex(c.saslMechanism)
            }
            if (page.hasPref("notifyHighlights")) {
                highlightSwitch.checked = c.notifyHighlights
                dmSwitch.checked = c.notifyDirectMessages
            }
            if (page.hasPref("reconnectLimit")) {
                retryField.text = String(c.reconnectLimit)
                authRetrySwitch.checked = c.reconnectAfterAuthFailure
            }
            if (page.hasPref("historyLimit")) {
                historyLimitField.text = String(c.historyLimit)
            }
            if (page.hasPref("defaultPartReason")) {
                defaultPartReasonField.text = c.defaultPartReason
            }
            if (page.hasPref("respondToCtcpVersion")) {
                ctcpVersionSwitch.checked = c.respondToCtcpVersion
            }
            if (c.serverPassword !== undefined && c.serverPassword !== null) {
                serverPassField.text = c.serverPassword
            }
            if (page.hasPref("showTimestamps")) {
                timestampsSwitch.checked = c.showTimestamps
            }
            if (c.nickname !== undefined && c.nickname.length > 0) {
                nickField.text = c.nickname
            }
        } else {
            page.autojoinModel = []
        }
    }

    // ---------------------------------------------------------------------- //
    // Layout
    // ---------------------------------------------------------------------- //
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- title bar + live search ----------------
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.topMargin: 8
            Layout.bottomMargin: 6
            spacing: 8

            Text {
                text: "kirc"
                color: page.fgAccent()
                font.family: page.mono
                font.pointSize: page.pt
                font.bold: true
            }

            Text {
                text: qsTr("settings")
                color: page.fgDim()
                font.family: page.mono
                font.pointSize: page.pt
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Layout.alignment: Qt.AlignVCenter
                implicitHeight: 1
                color: page.ruleC()
            }

            Controls.TextField {
                id: searchField
                Layout.preferredWidth: Math.max(Math.round(Kirigami.Units.gridUnit * 9),
                                                Math.min(page.width * 0.3, Math.round(Kirigami.Units.gridUnit * 16)))
                placeholderText: qsTr("search")
                font.family: page.mono
                font.pointSize: page.ptSmall
                color: page.fgMain()
                placeholderTextColor: page.fgDim()
                selectionColor: page.fgAccent()
                selectedTextColor: page.bgLogC()
                leftPadding: 6
                rightPadding: 6
                onTextChanged: page.setFilter(text)

                background: Rectangle {
                    implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
                    radius: 0
                    color: page.bgInputC()
                    border.width: 1
                    border.color: searchField.activeFocus ? page.fgAccent() : page.ruleC()
                }
            }
        }

        TermRule {}

        // ---------------- the two panes ----------------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- left: flat monospace navigation ----
            ColumnLayout {
                id: navPane
                Layout.fillHeight: true
                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 9.5)
                Layout.leftMargin: 4
                Layout.topMargin: 6
                spacing: 0

                Repeater {
                    model: page.sectionIds

                    Rectangle {
                        id: navRow

                        required property string modelData
                        required property int index

                        readonly property bool active: page.sectionIndex === navRow.index
                        readonly property bool hasMatch: page.sectionMatches(navRow.index)

                        Layout.fillWidth: true
                        implicitHeight: navLabel.implicitHeight + 8
                        color: navRow.active ? page.fgAccent()
                                             : (navMouse.containsMouse ? page.hoverC() : "transparent")

                        Text {
                            id: navLabel
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: (navRow.active ? "▌ " : "  ") + page.sectionName(navRow.index)
                                  + (page.filter.length > 0 ? " (" + page.sectionMatchCount(navRow.index) + ")" : "")
                            // Active row is inverse video; sections without a
                            // match dim out while filtering.
                            color: navRow.active ? page.bgLogC()
                                                 : (navRow.hasMatch ? page.fgMain() : page.fgDim())
                            font.family: page.mono
                            font.pointSize: page.pt
                            font.bold: navRow.active
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: navMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.selectSection(navRow.index)
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                Text {
                    Layout.leftMargin: 8
                    Layout.bottomMargin: 8
                    text: ThemeEngine.themeDisplayName(ThemeEngine.themeId) + " · " + ThemeEngine.fontFamily
                    color: page.fgDim()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            // ---- pane divider ----
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: page.ruleC()
            }

            // ---- right: the selected section ----
            Controls.ScrollView {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

                ColumnLayout {
                    width: scroll.availableWidth
                    spacing: 0

                    // "no settings match" hint (search found nothing anywhere)
                    Text {
                        Layout.fillWidth: true
                        Layout.margins: 10
                        visible: page.filter.length > 0 && !page.anyMatch()
                        text: qsTr("no settings match “%1”").arg(page.filter)
                        color: page.fgWarn()
                        font.family: page.mono
                        font.pointSize: page.ptSmall
                        elide: Text.ElideRight
                    }

                    // The selected section matched on its keywords but has no
                    // matching *rows* — say so instead of showing an empty pane.
                    Text {
                        Layout.fillWidth: true
                        Layout.margins: 10
                        visible: page.filter.length > 0 && page.sectionMatches(page.sectionIndex)
                                 && page.sectionMatchCount(page.sectionIndex) === 0
                        text: qsTr("no matching rows in this section — see the numbered sections")
                        color: page.fgDim()
                        font.family: page.mono
                        font.pointSize: page.ptSmall
                        elide: Text.ElideRight
                    }

                    // ========================================================== //
                    // Identity
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 0
                        spacing: 0

                        SectionHeader { title: page.sectionName(0) }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Nickname"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Nickname")
                                TermField {
                                    id: nickField
                                    placeholderText: qsTr("yournick")
                                    onEditingFinished: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("NickServ account"))
                            spacing: 0

                            TermRow {
                                label: qsTr("NickServ account")
                                TermField {
                                    id: nickservNickField
                                    placeholderText: qsTr("registered account")
                                    onEditingFinished: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("NickServ password"))
                            spacing: 0

                            TermRow {
                                label: qsTr("NickServ password")
                                TermField {
                                    id: nickservPassField
                                    echoMode: showNickservPass.checked ? TextInput.Normal : TextInput.Password
                                    placeholderText: qsTr("stored in kwallet")
                                    onEditingFinished: page.persist()
                                }
                                TermButton {
                                    id: showNickservPass
                                    checkable: true
                                    prompt: checked ? qsTr("[hide]") : qsTr("[show]")
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("stored in KWallet — never written to kirc.conf")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("SASL user"))
                            spacing: 0

                            TermRow {
                                label: qsTr("SASL user")
                                TermField {
                                    id: saslUserField
                                    placeholderText: qsTr("SASL account name")
                                    onEditingFinished: {
                                        var win = page.hostWindow
                                        if (win && win.appConfig) {
                                            win.appConfig.saslUser = text
                                            win.appConfig.save()
                                        }
                                    }
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("SASL mechanism"))
                            spacing: 0

                            TermRow {
                                label: qsTr("SASL mechanism")
                                TermCombo {
                                    id: saslMechBox
                                    model: [qsTr("Auto"), qsTr("PLAIN"), qsTr("EXTERNAL")]
                                    onActivated: {
                                        page.persist()
                                        var win = page.hostWindow
                                        if (win && win.saslMechanism !== undefined) {
                                            win.saslMechanism = page.saslMechanismId(currentIndex)
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("Auto negotiates SCRAM-SHA-256 when advertised, else PLAIN")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }
                    }

                    // ========================================================== //
                    // Connection
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 1
                        spacing: 0

                        SectionHeader { title: page.sectionName(1) }

                        // ---- server password (IRC PASS) ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Server password"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Server password")
                                TermField {
                                    id: serverPassField
                                    echoMode: showServerPass.checked ? TextInput.Normal : TextInput.Password
                                    placeholderText: qsTr("only if the server asks for one")
                                    onEditingFinished: page.persist()
                                }
                                TermButton {
                                    id: showServerPass
                                    checkable: true
                                    prompt: checked ? qsTr("[hide]") : qsTr("[show]")
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("sent as PASS before connect — stored in KWallet, never written to kirc.conf")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Identify"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Identify")
                                TermToggle {
                                    id: identifySwitch
                                    text: qsTr("Identify then autojoin")
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        // ---- CTCP VERSION auto-reply (privacy-relevant) ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("CTCP version")) && page.hasPref("respondToCtcpVersion")
                            spacing: 0

                            TermRow {
                                label: qsTr("CTCP version")
                                TermToggle {
                                    id: ctcpVersionSwitch
                                    text: qsTr("Reply to CTCP VERSION requests")
                                    checked: true
                                    onToggled: page.persist()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("answers CTCP VERSION with the client name and version — anyone who asks can see them")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Autojoin"))
                            spacing: 0

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.topMargin: 5
                                text: qsTr("Autojoin")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            Repeater {
                                model: page.autojoinModel

                                RowLayout {
                                    id: autojoinRow

                                    required property string modelData
                                    required property int index

                                    Layout.fillWidth: true
                                    Layout.leftMargin: 10
                                    Layout.rightMargin: 10
                                    Layout.topMargin: 2
                                    spacing: 8

                                    Text {
                                        Layout.fillWidth: true
                                        text: "# " + autojoinRow.modelData
                                        color: page.fgMain()
                                        font.family: page.mono
                                        font.pointSize: page.ptSmall
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: "[x]"
                                        color: removeMouse.containsMouse ? page.fgWarn() : page.fgDim()
                                        font.family: page.mono
                                        font.pointSize: page.ptSmall

                                        MouseArea {
                                            id: removeMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                var out = page.autojoinModel.slice()
                                                out.splice(autojoinRow.index, 1)
                                                page.autojoinModel = out
                                                page.persist()
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.topMargin: 2
                                visible: page.autojoinModel.length === 0
                                text: qsTr("no channels yet — joins on connect")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.topMargin: 4
                                spacing: 8

                                TermField {
                                    id: autojoinAddField
                                    placeholderText: qsTr("#channel")
                                    onAccepted: autojoinAddButton.clicked()
                                }

                                TermButton {
                                    id: autojoinAddButton
                                    prompt: qsTr("[add]")
                                    enabled: autojoinAddField.text.trim().length > 0
                                    onClicked: {
                                        var ch = autojoinAddField.text.trim()
                                        if (ch.length === 0) {
                                            return
                                        }
                                        var out = page.autojoinModel.slice()
                                        var key = ch.toLowerCase()
                                        var dup = false
                                        for (var i = 0; i < out.length; ++i) {
                                            if (String(out[i]).toLowerCase() === key) {
                                                dup = true
                                                break
                                            }
                                        }
                                        if (!dup) {
                                            out.push(ch)
                                            page.autojoinModel = out
                                            page.persist()
                                        }
                                        autojoinAddField.text = ""
                                    }
                                }
                            }

                            TermRule {}
                        }

                        // ---- history lines fetched on join (chathistory) ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("History")) && page.hasPref("historyLimit")
                            spacing: 0

                            TermRow {
                                label: qsTr("History")
                                TermField {
                                    id: historyLimitField
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 5)
                                    Layout.fillWidth: false
                                    placeholderText: qsTr("200 (0 = off)")
                                    inputMethodHints: Qt.ImhDigitsOnly
                                    validator: IntValidator { bottom: 0; top: 1000 }
                                    onEditingFinished: page.persist()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("lines fetched when a channel is joined (0 = off)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Reconnect"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Reconnect")
                                TermToggle {
                                    id: reconnectSwitch
                                    text: qsTr("Reconnect if dropped")
                                    checked: true
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Retry limit")) && page.hasPref("reconnectLimit")
                            spacing: 0

                            TermRow {
                                label: qsTr("Retry limit")
                                TermField {
                                    id: retryField
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 5)
                                    Layout.fillWidth: false
                                    placeholderText: qsTr("10 (0 = unlimited)")
                                    inputMethodHints: Qt.ImhDigitsOnly
                                    validator: IntValidator { bottom: 0; top: 999 }
                                    onEditingFinished: page.persist()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("automatic reconnect attempts (0 = unlimited)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Auth failures")) && page.hasPref("reconnectLimit")
                            spacing: 0

                            TermRow {
                                label: qsTr("Auth failures")
                                TermToggle {
                                    id: authRetrySwitch
                                    text: qsTr("Reconnect on auth failure")
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        // ---- default part/quit reason ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Part reason")) && page.hasPref("defaultPartReason")
                            spacing: 0

                            TermRow {
                                label: qsTr("Part reason")
                                TermField {
                                    id: defaultPartReasonField
                                    placeholderText: qsTr("Leaving")
                                    onEditingFinished: page.persist()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("used for /part and /quit when no reason is typed")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }
                    }

                    // ========================================================== //
                    // Appearance
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 2
                        spacing: 0

                        SectionHeader { title: page.sectionName(2) }

                        // ---- theme picker: flat monospace rows ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Theme"))
                            spacing: 0

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.topMargin: 5
                                text: qsTr("Theme")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            Repeater {
                                model: ThemeEngine.availableThemeIds

                                Rectangle {
                                    id: themeRow

                                    required property string modelData

                                    readonly property bool active: ThemeEngine.themeId === ThemeEngine.canonicalId(themeRow.modelData)
                                    readonly property var preview: ThemeEngine.themePreview(
                                        themeRow.modelData,
                                        page.fgAccent(),
                                        page.bgPanelC(),
                                        page.fgMain())

                                    Layout.fillWidth: true
                                    Layout.leftMargin: 10
                                    Layout.rightMargin: 10
                                    Layout.topMargin: 1
                                    implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.7)
                                    radius: 0
                                    color: themeRow.active ? page.selC()
                                                           : (themeMouse.containsMouse ? page.hoverC() : "transparent")
                                    border.width: 1
                                    border.color: themeRow.active ? page.fgAccent() : "transparent"

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 6
                                        anchors.rightMargin: 6
                                        spacing: 8

                                        Text {
                                            text: themeRow.active ? "▌" : " "
                                            color: page.fgAccent()
                                            font.family: page.mono
                                            font.pointSize: page.pt
                                            Layout.alignment: Qt.AlignVCenter
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: ThemeEngine.themeDisplayName(themeRow.modelData)
                                            color: themeRow.active ? page.fgAccent() : page.fgMain()
                                            font.family: page.mono
                                            font.pointSize: page.ptSmall
                                            font.bold: themeRow.active
                                            elide: Text.ElideRight
                                            Layout.alignment: Qt.AlignVCenter
                                        }

                                        // Swatch strip (accent / log / panel). Plain
                                        // rectangles — no nested Repeater, which
                                        // SIGSEGVs Qt 6.11 inside contentItems.
                                        Row {
                                            spacing: 2
                                            Layout.alignment: Qt.AlignVCenter

                                            Rectangle {
                                                implicitWidth: 10
                                                implicitHeight: 10
                                                color: themeRow.preview.accent
                                                border.width: 1
                                                border.color: page.ruleC()
                                            }
                                            Rectangle {
                                                implicitWidth: 10
                                                implicitHeight: 10
                                                color: themeRow.preview.log
                                                border.width: 1
                                                border.color: page.ruleC()
                                            }
                                            Rectangle {
                                                implicitWidth: 10
                                                implicitHeight: 10
                                                color: themeRow.preview.panel
                                                border.width: 1
                                                border.color: page.ruleC()
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: themeMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: page.selectTheme(themeRow.modelData)
                                    }
                                }
                            }

                            TermRule {}
                        }

                        // ---- font family (monospace list) ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Font family"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Font family")

                                TermCombo {
                                    id: fontFamilyBox
                                    Layout.fillWidth: false
                                    implicitWidth: Math.round(Kirigami.Units.gridUnit * 13)
                                    model: page.fontFamilies
                                    currentIndex: Math.max(0, page.fontFamilies.indexOf(ThemeEngine.fontFamily))
                                    onActivated: {
                                        var fam = fontFamilyBox.textAt(currentIndex)
                                        // "monospace" is the theme default: an
                                        // empty override keeps the theme in charge.
                                        ThemeEngine.fontFamilyOverride = (fam === "monospace") ? "" : fam
                                        page.persist()
                                    }
                                }
                            }

                            TermRule {}
                        }

                        // ---- font size ----
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Font size"))
                            spacing: 0

                            TermRow {
                                label: qsTr("Font size")

                                Controls.Slider {
                                    id: fontSlider
                                    Layout.fillWidth: true
                                    from: -2
                                    to: 6
                                    stepSize: 1
                                    value: ThemeEngine.fontDelta
                                    onMoved: {
                                        ThemeEngine.fontDelta = value
                                        page.persist()
                                    }

                                    background: Rectangle {
                                        x: fontSlider.leftPadding
                                        y: fontSlider.topPadding + fontSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 120
                                        implicitHeight: 4
                                        width: fontSlider.availableWidth
                                        height: 2
                                        radius: 0
                                        color: page.ruleC()

                                        Rectangle {
                                            width: fontSlider.visualPosition * parent.width
                                            height: parent.height
                                            radius: 0
                                            color: page.fgAccent()
                                        }
                                    }

                                    handle: Rectangle {
                                        x: fontSlider.leftPadding + fontSlider.visualPosition * (fontSlider.availableWidth - width)
                                        y: fontSlider.topPadding + fontSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 9
                                        implicitHeight: 14
                                        radius: 0
                                        color: fontSlider.pressed ? page.fgAccent() : page.bgInputC()
                                        border.width: 1
                                        border.color: page.fgAccent()
                                    }
                                }

                                Text {
                                    text: (ThemeEngine.fontDelta >= 0 ? "+" : "") + ThemeEngine.fontDelta
                                    color: page.fgDim()
                                    font.family: page.mono
                                    font.pointSize: page.ptSmall
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("Aa — the quick brown fox")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: ThemeEngine.resolvePointSize(ThemeEngine.messageSize, page.pt)
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Timestamps")) && page.hasPref("showTimestamps")
                            spacing: 0

                            TermRow {
                                label: qsTr("Timestamps")
                                TermToggle {
                                    id: timestampsSwitch
                                    text: qsTr("Show message timestamps")
                                    checked: true
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }
                    }

                    // ========================================================== //
                    // Notifications
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 3
                        spacing: 0

                        SectionHeader { title: page.sectionName(3) }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Highlights")) && page.hasPref("notifyHighlights")
                            spacing: 0

                            TermRow {
                                label: qsTr("Highlights")
                                TermToggle {
                                    id: highlightSwitch
                                    text: qsTr("Notify on highlight")
                                    checked: true
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Direct messages")) && page.hasPref("notifyHighlights")
                            spacing: 0

                            TermRow {
                                label: qsTr("Direct messages")
                                TermToggle {
                                    id: dmSwitch
                                    text: qsTr("Notify on direct message")
                                    checked: true
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("System tray"))
                            spacing: 0

                            TermRow {
                                label: qsTr("System tray")
                                TermToggle {
                                    id: traySwitch
                                    text: qsTr("Minimize to tray on close")
                                    onToggled: page.persist()
                                }
                            }
                            TermRule {}
                        }
                    }

                    // ========================================================== //
                    // About
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 4
                        spacing: 0

                        SectionHeader { title: page.sectionName(4) }

                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 4
                            text: qsTr("# kIRC 0.1.0 — IRC in a terminal coat.\n# Kirigami + Qt Quick, monospace everywhere, no bubbles.")
                            color: page.fgMain()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                            wrapMode: Text.WordWrap
                        }

                        TermRule { Layout.topMargin: 8 }

                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 6
                            text: qsTr("Passwords are never written to kirc.conf: the NickServ password lives in KWallet, the SASL password lives only in memory for this session.")
                            color: page.fgDim()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                            wrapMode: Text.WordWrap
                        }

                        TermRule { Layout.topMargin: 8 }
                    }

                    Item {
                        Layout.preferredHeight: Kirigami.Units.largeSpacing
                    }
                }
            }
        }
    }
}
