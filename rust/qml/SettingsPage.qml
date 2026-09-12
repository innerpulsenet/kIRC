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
//     (PASS) passwords go to the platform secret store (kircConfig
//     .secretBackendName names it) via KircConfig, the SASL password is
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
    // Backend name for secret-store wording, taken from KircConfig so no text
    // here claims a platform it is not running on ("KWallet" on Linux,
    // "Windows Credential Manager" on Windows).  The fallback is only for
    // standalone harnesses without a config object.
    readonly property string secretBackendName:
        page.kircConfig !== null && page.kircConfig !== undefined
                && page.kircConfig.secretBackendName !== undefined
            ? String(page.kircConfig.secretBackendName)
            : qsTr("the system secret store")
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
    // background, so `breeze` still follows the user's scheme). The glass
    // sheet (p8) tints it with the palette-resolved colour either way.
    background: Rectangle {
        color: page.bgLogC()

        GlassSurface {
            anchors.fill: parent
            radius: 0
            tint: ThemeEngine.glassFillFor(page.bgLogC())
        }
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

    readonly property var sectionIds: ["identity", "connection", "appearance", "effects", "notifications", "about"]

    // Search keywords per section, and the row labels each section contains
    // (used by the live filter).
    readonly property var sectionKeywords: [
        ["identity", "nickname", "nickserv", "account", "password", "sasl", "mechanism", "user", "plain", "external", "auto"],
        ["connection", "autojoin", "channel", "password", "server", "pass", "history", "lines", "scrollback", "reconnect", "retry", "authentication", "identify", "part", "quit", "reason", "leave", "ctcp", "version", "client", "reply", "privacy"],
        ["appearance", "theme", "font", "size", "timestamps", "colour", "color", "palette",
         "retro", "bbs", "ansi", "dial-up", "c64", "commodore", "vt", "dec", "ega", "dos",
         "synthwave", "neon", "outrun", "phosphor", "amber",
         "crt", "scanlines", "paper", "teletype", "gruvbox"],
        ["effects", "effect", "glass", "frost", "blur", "sheen", "reflection", "shine", "gloss",
         "edge", "depth", "translucent", "polish", "specular",
         "crt", "scanline", "scanlines", "interlace", "vignette", "corner",
         "falloff", "grain", "noise", "film", "flicker", "hum", "humbar", "hum bar", "roll",
         "tube", "monitor", "screen", "filter", "retro"],
        ["notifications", "notification", "highlight", "direct message", "tray", "minimize"],
        ["about", "version", "kirc", "license", "kde", "passwords"]
    ]
    readonly property var sectionRowLabels: [
        ["Nickname", "NickServ account", "NickServ password", "SASL user", "SASL mechanism"],
        ["Server password", "Identify", "CTCP version", "Autojoin", "History", "Reconnect", "Retry limit", "Auth failures", "Part reason"],
        ["Theme", "Font family", "Font size", "Timestamps"],
        ["Glass", "Glass intensity", "Glass frost", "Glass sheen", "Glass edges",
         "Reflection", "Reflection intensity",
         "Scanlines", "Scanline intensity", "Vignette", "Vignette intensity", "Grain", "Grain intensity",
         "Flicker", "Flicker intensity", "Hum bar", "Hum bar intensity"],
        ["Highlights", "Direct messages", "System tray"],
        ["Version", "Passwords"]
    ]

    function sectionName(i)
    {
        switch (i) {
        case 0: return qsTr("Identity")
        case 1: return qsTr("Connection")
        case 2: return qsTr("Appearance")
        case 3: return qsTr("Effects")
        case 4: return qsTr("Notifications")
        case 5: return qsTr("About")
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
        // The Appearance section's theme picker is a list of rows of its own:
        // a filter that matches a theme (id, name or keyword) counts as a
        // matching row, so the picker is shown instead of the "no matching
        // rows" hint.
        if (i === 2 && n === 0 && page.themeKeywordMatch()) {
            n = 1
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

    // --- theme picker search ------------------------------------------------
    // The Appearance section's theme picker is a list of themes, so a live
    // filter must find them like a row label. Each theme id carries search
    // keywords ("bbs", "commodore", "dos", "outrun", ...), and the rows
    // filter down to the matches instead of the whole list disappearing.
    readonly property var themeSearchKeywords: {
        "tui": "terminal console monospace default neutral",
        "phosphor": "green p1 crt tube retro",
        "amber": "orange p3 crt tube retro",
        "ice": "cold blue warp",
        "breeze": "desktop scheme kde palette light dark",
        "bbs": "bbs bulletin board dial-up ansi sysop door",
        "c64": "commodore 64 breadbin vic-20 home computer blue",
        "vt": "dec vt100 vt220 terminal phosphor",
        "ega": "ega dos ibm pc bios vga 16-colour 16-color",
        "synthwave": "neon outrun synth eighties 80s retro",
        "ai-slop": "ai slop vibe purple violet magenta neon gradient omarchy quattro",
        // p10 additions.  Each new id must carry keywords here: the settings
        // search only finds a theme by its id, its display name or this list,
        // and the smoke test asserts every built-in has one.
        "crt": "crt scanlines scanline tube aged ntsc colour color phosphor retro filter",
        "paper": "paper teletype light ink print white ribbon",
        "gruvbox": "gruvbox warm retro brown orange cream aqua"
    }

    /// True when a theme id (or its display name / keywords) matches the
    /// filter; an empty filter matches everything.
    function themeRowMatches(id)
    {
        if (page.filter.length === 0) {
            return true
        }
        var kw = page.themeSearchKeywords[id]
        return page.matches(String(id), page.filter)
                || page.matches(ThemeEngine.themeDisplayName(id), page.filter)
                || (kw !== undefined && page.matches(kw, page.filter))
    }

    /// True when any theme in the picker matches the filter.
    function themeKeywordMatch()
    {
        var ids = ThemeEngine.availableThemeIds
        for (var i = 0; i < ids.length; ++i) {
            if (page.themeRowMatches(ids[i])) {
                return true
            }
        }
        return false
    }

    /// Visibility of one theme row: everything shows while the filter is off
    /// (or literally searches for "Theme"), otherwise only the matches.
    function themeRowVisible(id)
    {
        return page.rowVisible(qsTr("Theme")) || page.themeRowMatches(id)
    }

    /// Visibility of the whole picker: shown when a theme matches, so
    /// searching "bbs" / "commodore" / "neon" lands on the theme list.
    function themeListVisible()
    {
        return page.filter.length === 0 || page.rowVisible(qsTr("Theme"))
                || page.themeKeywordMatch()
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
        page.selectSection(page.sectionIds.indexOf("about"))
    }

    // main.qml (openEffectsSettings, from the [effects] popup) selects the
    // Effects section.  Resolved by id so the section list stays the single
    // authority on its own order.
    function showEffects()
    {
        page.selectSection(page.sectionIds.indexOf("effects"))
    }

    // --- CRT effect prefs (p10) --------------------------------------------
    // The KircConfig object is the source of truth for these (there is no
    // ThemeEngine property for them: they are global display prefs, not theme
    // tokens).  The controls below read it through these helpers and write it
    // back through persist(), so a change made here — or in the [effects]
    // popup, which writes the same keys — is live in the window and survives a
    // restart.  A config double without the keys (an older harness) simply
    // shows the all-off defaults.
    function prefBool(name, fallback)
    {
        var c = page.cfg()
        if (c === null || c === undefined || c[name] === undefined) {
            return fallback === true
        }
        return c[name] === true
    }

    function prefInt(name, fallback)
    {
        var c = page.cfg()
        if (c === null || c === undefined || c[name] === undefined) {
            return fallback
        }
        var n = parseInt(c[name], 10)
        return isNaN(n) ? fallback : n
    }

    /// Flip one effect's switch in the config and persist.  main.qml mirrors
    /// the NOTIFY signal into the overlay, so the window updates live.
    function setEffectPref(name, on)
    {
        var c = page.cfg()
        if (c === null || c === undefined || c[name] === undefined) {
            return
        }
        c[name] = on === true
        page.persist()
    }

    /// Set one effect's intensity (1..100; KircConfig clamps) and persist.
    function setEffectAmount(name, value)
    {
        var c = page.cfg()
        if (c === null || c === undefined || c[name] === undefined) {
            return
        }
        var n = Math.round(Number(value))
        if (isNaN(n) || c[name] === n) {
            return
        }
        c[name] = n
        page.persist()
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

    /// Flat square slider on a box-drawing rule with an accent fill: the
    /// terminal take on Controls.Slider.  Same shape as the glass intensity
    /// control, factored out for the five effect intensities.
    component TermSlider: Controls.Slider {
        id: termSlider

        Layout.fillWidth: true
        from: 1
        to: 100
        stepSize: 1

        background: Rectangle {
            x: termSlider.leftPadding
            y: termSlider.topPadding + termSlider.availableHeight / 2 - height / 2
            implicitWidth: 120
            implicitHeight: 4
            width: termSlider.availableWidth
            height: 2
            radius: 0
            color: page.ruleC()

            Rectangle {
                width: termSlider.visualPosition * parent.width
                height: parent.height
                radius: 0
                color: termSlider.enabled ? page.fgAccent() : page.fgDim()
            }
        }

        handle: Rectangle {
            x: termSlider.leftPadding + termSlider.visualPosition * (termSlider.availableWidth - width)
            y: termSlider.topPadding + termSlider.availableHeight / 2 - height / 2
            implicitWidth: 9
            implicitHeight: 14
            radius: 0
            color: termSlider.pressed ? page.fgAccent() : page.bgInputC()
            border.width: 1
            border.color: termSlider.enabled ? page.fgAccent() : page.fgDim()
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
        // Password first: secret-store write, never kirc.conf (see KircConfig).
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
        // The server password is a secret like the others: it goes to the
        // platform secret store through KircConfig.save(), never into
        // kirc.conf.
        c.serverPassword = serverPassField.text
        if (page.hasPref("showTimestamps")) {
            c.showTimestamps = timestampsSwitch.checked
        }
        if (page.hasPref("glassEffects")) {
            c.glassEffects = ThemeEngine.glassEffects
            c.glassIntensity = ThemeEngine.glassIntensity
            c.glassBlur = ThemeEngine.glassBlur
            c.glassSheen = ThemeEngine.glassSheen
            c.glassEdges = ThemeEngine.glassEdges
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

    // --- glass surfacing sync ----------------------------------------------
    // ThemeEngine is the live source of truth (every surface binds to it), so
    // the controls follow it in both directions: a change made anywhere —
    // this pane, main.qml restoring kirc.conf, a future menu entry — lands on
    // the controls, and a control change lands on the engine.
    Connections {
        target: ThemeEngine

        function onGlassEffectsChanged() {
            glassSwitch.checked = ThemeEngine.glassEffects
        }
        function onGlassIntensityChanged() {
            if (Math.round(glassSlider.value) !== ThemeEngine.glassIntensity) {
                glassSlider.value = ThemeEngine.glassIntensity
            }
        }
        function onGlassBlurChanged() {
            glassBlurSwitch.checked = ThemeEngine.glassBlur
        }
        function onGlassSheenChanged() {
            glassSheenSwitch.checked = ThemeEngine.glassSheen
        }
        function onGlassEdgesChanged() {
            glassEdgesSwitch.checked = ThemeEngine.glassEdges
        }
    }

    // --- CRT effects: follow the config in both directions -----------------
    // Unlike glass these live in KircConfig itself (global prefs, no theme
    // token), so the pane binds to the config object.  The handlers keep the
    // controls honest when the value changes elsewhere — the [effects] popup,
    // or main.qml restoring kirc.conf at startup.
    Connections {
        target: page.cfg()
        enabled: page.cfg() !== null && page.cfg().scanlines !== undefined

        function onScanlinesChanged() {
            scanlineSwitch.checked = page.prefBool("scanlines")
        }
        function onScanlineAmountChanged() {
            if (Math.round(scanlineSlider.value) !== page.prefInt("scanlineAmount", 35)) {
                scanlineSlider.value = page.prefInt("scanlineAmount", 35)
            }
        }
        function onVignetteChanged() {
            vignetteSwitch.checked = page.prefBool("vignette")
        }
        function onVignetteAmountChanged() {
            if (Math.round(vignetteSlider.value) !== page.prefInt("vignetteAmount", 30)) {
                vignetteSlider.value = page.prefInt("vignetteAmount", 30)
            }
        }
        function onGrainChanged() {
            grainSwitch.checked = page.prefBool("grain")
        }
        function onGrainAmountChanged() {
            if (Math.round(grainSlider.value) !== page.prefInt("grainAmount", 10)) {
                grainSlider.value = page.prefInt("grainAmount", 10)
            }
        }
        function onFlickerChanged() {
            flickerSwitch.checked = page.prefBool("flicker")
        }
        function onFlickerAmountChanged() {
            if (Math.round(flickerSlider.value) !== page.prefInt("flickerAmount", 4)) {
                flickerSlider.value = page.prefInt("flickerAmount", 4)
            }
        }
        function onHumBarChanged() {
            humSwitch.checked = page.prefBool("humBar")
        }
        function onHumBarAmountChanged() {
            if (Math.round(humSlider.value) !== page.prefInt("humBarAmount", 8)) {
                humSlider.value = page.prefInt("humBarAmount", 8)
            }
        }
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
            // Glass surfacing: the persisted [UI] Glass* prefs are pushed into
            // ThemeEngine (the singleton every GlassSurface binds to) and
            // mirrored by the controls. Live, no restart.
            if (page.hasPref("glassEffects")) {
                ThemeEngine.glassEffects = c.glassEffects
                ThemeEngine.glassIntensity = c.glassIntensity
                ThemeEngine.glassBlur = c.glassBlur
                ThemeEngine.glassSheen = c.glassSheen
                ThemeEngine.glassEdges = c.glassEdges
                glassSwitch.checked = ThemeEngine.glassEffects
                glassSlider.value = ThemeEngine.glassIntensity
                glassBlurSwitch.checked = ThemeEngine.glassBlur
                glassSheenSwitch.checked = ThemeEngine.glassSheen
                glassEdgesSwitch.checked = ThemeEngine.glassEdges
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
                                    placeholderText: qsTr("stored in %1").arg(page.secretBackendName)
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
                                text: qsTr("stored in %1 — never written to kirc.conf").arg(page.secretBackendName)
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            // Save-failure status from KircConfig.save() (e.g.
                            // the secret store was unavailable).  Passive:
                            // a small line, no dialogs; empty = nothing to say.
                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                visible: page.kircConfig !== null && page.kircConfig !== undefined
                                         && page.kircConfig.secretsStatus !== undefined
                                         && String(page.kircConfig.secretsStatus).length > 0
                                text: visible ? String(page.kircConfig.secretsStatus) : ""
                                color: page.fgWarn()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                wrapMode: Text.WordWrap
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
                                text: qsTr("sent as PASS before connect — stored in %1, never written to kirc.conf").arg(page.secretBackendName)
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            // Same passive save-failure status as under the
                            // NickServ password above.
                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                visible: page.kircConfig !== null && page.kircConfig !== undefined
                                         && page.kircConfig.secretsStatus !== undefined
                                         && String(page.kircConfig.secretsStatus).length > 0
                                text: visible ? String(page.kircConfig.secretsStatus) : ""
                                color: page.fgWarn()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                wrapMode: Text.WordWrap
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

                        // ---- theme picker: flat monospace rows -----------------------------
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.themeListVisible()
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
                                    // The picker filters with the live search:
                                    // a matching theme stays, the rest hide.
                                    visible: page.themeRowVisible(themeRow.modelData)
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
                    // Effects (p10) — ONE section for BOTH effect families
                    //
                    //   * GLASS: the frosted sheet's master switch, its
                    //     intensity and its four layers (frost, sheen, edges,
                    //     reflection).  The first three are the p8 prefs and
                    //     stay single-sourced in ThemeEngine; reflection is the
                    //     p10 chrome gloss in KircConfig.
                    //   * CRT: scanlines, vignette, grain, flicker, hum bar —
                    //     global [UI] keys in cpp/kircconfig.cpp.
                    //
                    // None of it is a theme token: switching theme cannot
                    // enable or disable any of it.  Every effect is OFF by
                    // default (the glass master is the one the app has always
                    // had on) because the CRT layers sit over the message text.
                    // main.qml mirrors the config into the overlay, so a toggle
                    // here is live — and the [effects] header popup writes the
                    // same keys, which is why the controls follow the config
                    // object rather than a local copy.
                    //
                    // This section replaced the standalone Glass pane (p10):
                    // one surface, one search target for "glass", "frost",
                    // "scanlines", "reflection" and the rest.
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 3
                        spacing: 0

                        SectionHeader { title: page.sectionName(3) }

                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 4
                            Layout.bottomMargin: 4
                            text: qsTr("Two families: the in-app glass sheet (frost, sheen, edges, reflection) and the CRT tube (scanlines, vignette, grain, flicker, hum bar). All global display settings — the theme cannot change them.")
                            color: page.fgDim()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                            wrapMode: Text.WordWrap
                        }

                        // Capability caption (software scene graph only): the
                        // section stays visible with every value intact, but
                        // the controls are read-only and say why. The saved
                        // prefs are not touched by the degradation, so a
                        // hardware backend (KIRC_QUICK_BACKEND) brings the
                        // configured effects back unchanged.
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.bottomMargin: 4
                            visible: !ThemeEngine.effectsSupported
                            text: ThemeEngine.effectsUnsupportedReason
                            color: page.fgWarn()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                            wrapMode: Text.WordWrap
                        }

                        TermRule { Layout.topMargin: 6 }

                        // ---- glass family ----------------------------------- //
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 4
                            Layout.bottomMargin: 2
                            text: "-- glass --"
                            color: page.fgAccent()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Glass")) && page.hasPref("glassEffects")
                            spacing: 0

                            TermRow {
                                label: qsTr("Glass")
                                TermToggle {
                                    id: glassSwitch
                                    text: qsTr("Frosted glass effects")
                                    enabled: ThemeEngine.effectsSupported
                                    onToggled: {
                                        ThemeEngine.glassEffects = checked
                                        page.persist()
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("frost, reflection sheen and lit edges over the console panes — in-app only, off for the plain terminal look")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Glass intensity")) && page.hasPref("glassEffects")
                            spacing: 0

                            TermRow {
                                label: qsTr("Glass intensity")

                                Controls.Slider {
                                    id: glassSlider
                                    objectName: "glassSlider"
                                    Layout.fillWidth: true
                                    from: 1
                                    to: 100
                                    stepSize: 1
                                    enabled: ThemeEngine.glassEffects
                                             && ThemeEngine.effectsSupported
                                    value: ThemeEngine.glassIntensity
                                    // onValueChanged (not onMoved): covers a
                                    // drag, the wheel, the arrow keys and
                                    // increase()/decrease() alike, and the
                                    // guard keeps the engine->slider sync
                                    // from re-persisting the same value.
                                    onValueChanged: {
                                        if (ThemeEngine.glassIntensity !== Math.round(value)) {
                                            ThemeEngine.glassIntensity = Math.round(value)
                                            page.persist()
                                        }
                                    }

                                    background: Rectangle {
                                        x: glassSlider.leftPadding
                                        y: glassSlider.topPadding + glassSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 120
                                        implicitHeight: 4
                                        width: glassSlider.availableWidth
                                        height: 2
                                        radius: 0
                                        color: page.ruleC()

                                        Rectangle {
                                            width: glassSlider.visualPosition * parent.width
                                            height: parent.height
                                            radius: 0
                                            color: page.fgAccent()
                                        }
                                    }

                                    handle: Rectangle {
                                        x: glassSlider.leftPadding + glassSlider.visualPosition * (glassSlider.availableWidth - width)
                                        y: glassSlider.topPadding + glassSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 9
                                        implicitHeight: 14
                                        radius: 0
                                        color: glassSlider.pressed ? page.fgAccent() : page.bgInputC()
                                        border.width: 1
                                        border.color: page.fgAccent()
                                    }
                                }

                                Text {
                                    text: ThemeEngine.glassIntensity
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
                                text: qsTr("how strongly the frost, sheen and edges show (1–100)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Glass frost")) && page.hasPref("glassEffects")
                            spacing: 0

                            TermRow {
                                label: qsTr("Glass frost")
                                TermToggle {
                                    id: glassBlurSwitch
                                    text: qsTr("Frost (blurred underlay)")
                                    enabled: ThemeEngine.glassEffects
                                             && ThemeEngine.effectsSupported
                                    onToggled: {
                                        ThemeEngine.glassBlur = checked
                                        page.persist()
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("the frosted blur itself; the source is a static underlay, never the log")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Glass sheen")) && page.hasPref("glassEffects")
                            spacing: 0

                            TermRow {
                                label: qsTr("Glass sheen")
                                TermToggle {
                                    id: glassSheenSwitch
                                    text: qsTr("Reflection sheen")
                                    enabled: ThemeEngine.glassEffects
                                             && ThemeEngine.effectsSupported
                                    onToggled: {
                                        ThemeEngine.glassSheen = checked
                                        page.persist()
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("the diagonal reflection sweep across each pane")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Glass edges")) && page.hasPref("glassEffects")
                            spacing: 0

                            TermRow {
                                label: qsTr("Glass edges")
                                TermToggle {
                                    id: glassEdgesSwitch
                                    text: qsTr("Lit edges and depth")
                                    enabled: ThemeEngine.glassEffects
                                             && ThemeEngine.effectsSupported
                                    onToggled: {
                                        ThemeEngine.glassEdges = checked
                                        page.persist()
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("the lit top edge, the shading and the pane's depth")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Reflection")) && page.hasPref("reflection")
                            spacing: 0

                            TermRow {
                                label: qsTr("Reflection")
                                TermToggle {
                                    id: reflectionSwitch
                                    text: qsTr("Specular chrome gloss")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("reflection")
                                    onToggled: page.setEffectPref("reflection", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("a gloss along the window's own top edge and header band — static chrome only, never a mirror of the message log")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Reflection intensity")) && page.hasPref("reflection")
                            spacing: 0

                            TermRow {
                                label: qsTr("Reflection intensity")

                                TermSlider {
                                    id: reflectionSlider
                                    objectName: "reflectionSlider"
                                    enabled: page.prefBool("reflection")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("reflectionAmount", 25)
                                    onValueChanged: page.setEffectAmount("reflectionAmount", value)
                                }

                                Text {
                                    text: page.prefInt("reflectionAmount", 25)
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
                                text: qsTr("how bright the gloss and the top edge are (1–100)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        // ---- CRT family ------------------------------------- //
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 4
                            Layout.bottomMargin: 2
                            text: "-- crt --"
                            color: page.fgAccent()
                            font.family: page.mono
                            font.pointSize: page.ptSmall
                        }

                        // ---- scanlines ------------------------------------- //
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Scanlines")) && page.hasPref("scanlines")
                            spacing: 0

                            TermRow {
                                label: qsTr("Scanlines")
                                TermToggle {
                                    id: scanlineSwitch
                                    text: qsTr("Horizontal scanlines")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("scanlines")
                                    onToggled: page.setEffectPref("scanlines", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("a dark line every third row, drawn above every layer")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Scanline intensity")) && page.hasPref("scanlines")
                            spacing: 0

                            TermRow {
                                label: qsTr("Scanline intensity")

                                TermSlider {
                                    id: scanlineSlider
                                    objectName: "scanlineSlider"
                                    enabled: page.prefBool("scanlines")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("scanlineAmount", 35)
                                    onValueChanged: page.setEffectAmount("scanlineAmount", value)
                                }

                                Text {
                                    text: page.prefInt("scanlineAmount", 35)
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
                                text: qsTr("how dark the lines are (1–100); ~35 reads as a tube, much above that starts to eat the text")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        // ---- vignette -------------------------------------- //
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Vignette")) && page.hasPref("vignette")
                            spacing: 0

                            TermRow {
                                label: qsTr("Vignette")
                                TermToggle {
                                    id: vignetteSwitch
                                    text: qsTr("Corner falloff")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("vignette")
                                    onToggled: page.setEffectPref("vignette", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("the darkened tube corners of a real monitor")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Vignette intensity")) && page.hasPref("vignette")
                            spacing: 0

                            TermRow {
                                label: qsTr("Vignette intensity")

                                TermSlider {
                                    id: vignetteSlider
                                    objectName: "vignetteSlider"
                                    enabled: page.prefBool("vignette")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("vignetteAmount", 30)
                                    onValueChanged: page.setEffectAmount("vignetteAmount", value)
                                }

                                Text {
                                    text: page.prefInt("vignetteAmount", 30)
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
                                text: qsTr("how far the corner shading reaches in (1–100)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        // ---- grain ----------------------------------------- //
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Grain")) && page.hasPref("grain")
                            spacing: 0

                            TermRow {
                                label: qsTr("Grain")
                                TermToggle {
                                    id: grainSwitch
                                    text: qsTr("Static grain")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("grain")
                                    onToggled: page.setEffectPref("grain", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("a faint fixed noise wash — painted once, never animated")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Grain intensity")) && page.hasPref("grain")
                            spacing: 0

                            TermRow {
                                label: qsTr("Grain intensity")

                                TermSlider {
                                    id: grainSlider
                                    objectName: "grainSlider"
                                    enabled: page.prefBool("grain")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("grainAmount", 10)
                                    onValueChanged: page.setEffectAmount("grainAmount", value)
                                }

                                Text {
                                    text: page.prefInt("grainAmount", 10)
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
                                text: qsTr("density of the noise wash (1–100); it should read as texture, not as dirt")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        // ---- flicker --------------------------------------- //
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Flicker")) && page.hasPref("flicker")
                            spacing: 0

                            TermRow {
                                label: qsTr("Flicker")
                                TermToggle {
                                    id: flickerSwitch
                                    text: qsTr("Slow brightness flicker")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("flicker")
                                    onToggled: page.setEffectPref("flicker", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("a very slow, very shallow brightness breathing — the only effect that repaints while it runs")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Flicker intensity")) && page.hasPref("flicker")
                            spacing: 0

                            TermRow {
                                label: qsTr("Flicker intensity")

                                TermSlider {
                                    id: flickerSlider
                                    objectName: "flickerSlider"
                                    enabled: page.prefBool("flicker")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("flickerAmount", 4)
                                    onValueChanged: page.setEffectAmount("flickerAmount", value)
                                }

                                Text {
                                    text: page.prefInt("flickerAmount", 4)
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
                                text: qsTr("depth of the dip (1–100); the default is barely there on purpose")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        // ---- hum bar --------------------------------------- //
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Hum bar")) && page.hasPref("humBar")
                            spacing: 0

                            TermRow {
                                label: qsTr("Hum bar")
                                TermToggle {
                                    id: humSwitch
                                    text: qsTr("Rolling hum bar")
                                    enabled: ThemeEngine.effectsSupported
                                    checked: page.prefBool("humBar")
                                    onToggled: page.setEffectPref("humBar", checked)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 10
                                Layout.rightMargin: 10
                                Layout.bottomMargin: 5
                                text: qsTr("a band of brightness drifting slowly down the window, like a failing tube")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: page.rowVisible(qsTr("Hum bar intensity")) && page.hasPref("humBar")
                            spacing: 0

                            TermRow {
                                label: qsTr("Hum bar intensity")

                                TermSlider {
                                    id: humSlider
                                    objectName: "humSlider"
                                    enabled: page.prefBool("humBar")
                                             && ThemeEngine.effectsSupported
                                    value: page.prefInt("humBarAmount", 8)
                                    onValueChanged: page.setEffectAmount("humBarAmount", value)
                                }

                                Text {
                                    text: page.prefInt("humBarAmount", 8)
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
                                text: qsTr("how bright the band is (1–100)")
                                color: page.fgDim()
                                font.family: page.mono
                                font.pointSize: page.ptSmall
                                elide: Text.ElideRight
                            }

                            TermRule {}
                        }
                    }

                    // ========================================================== //
                    // Notifications
                    // ========================================================== //
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: page.sectionIndex === 4
                        spacing: 0

                        SectionHeader { title: page.sectionName(4) }

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
                        visible: page.sectionIndex === 5
                        spacing: 0

                        SectionHeader { title: page.sectionName(5) }

                        Text {
                            objectName: "aboutVersionText"
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.topMargin: 4
                            text: qsTr("# kIRC %1 — IRC in a terminal coat.\n# Kirigami + Qt Quick, monospace everywhere, no bubbles.")
                                  .arg(Qt.application.version)
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
                            text: qsTr("Passwords are never written to kirc.conf: the NickServ password lives in %1, the SASL password lives only in memory for this session.").arg(page.secretBackendName)
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
