// SPDX-License-Identifier: GPL-2.0-or-later
//
// SettingsPage — modern settings pane: sectioned cards, live search filter,
// every control persisted through KircConfig.  Passwords are never written
// to kirc.conf: the NickServ password goes to KWallet (see cpp/kircconfig.h),
// the SASL password stays session-only and is not editable here.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirc

// Delegates (autojoin list, theme picker) reference the page's functions and
// properties; bound component behaviour resolves those statically instead of
// through the dynamic context, and keeps qmllint clean.
pragma ComponentBehavior: Bound

Kirigami.ScrollablePage {
    id: page

    property var kircConfig: null
    // Lets the window find an already-open instance (openSettings/openAbout).
    readonly property bool isKircSettingsPage: true

    title: qsTr("Settings")

    // Search text; each card/row binds its visibility to it.
    property string filter: ""

    // About anchors at the bottom; showAbout() scrolls there.
    property var aboutCard: null

    // A small round colour dot for the theme picker's preview strip.  An
    // inline component keeps the three dots identical without a Repeater
    // (see the contentItem note in the Appearance card).
    component ThemeSwatch: Rectangle {
        width: Math.round(Kirigami.Units.gridUnit * 0.75)
        height: width
        radius: width / 2
        border.width: 1
        border.color: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.35)
    }

    function sectionVisible(matches)
    {
        if (page.filter.length === 0) {
            return true
        }
        for (var i = 0; i < matches.length; ++i) {
            if (matches[i].toLowerCase().indexOf(page.filter.toLowerCase()) >= 0) {
                return true
            }
        }
        return false
    }

    function rowVisible(label)
    {
        return page.filter.length === 0
            || label.toLowerCase().indexOf(page.filter.toLowerCase()) >= 0
    }

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
        if (page.hasPref("showTimestamps")) {
            c.showTimestamps = timestampsSwitch.checked
        }
        c.save()
    }

    /// Apply a built-in theme and persist the pick.  ThemeEngine is a
    /// singleton every surface binds to, so the switch is live; the picker's
    /// selection markers and the density radios follow automatically.  An
    /// unknown id leaves the active theme untouched (never persist a dead id).
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

    function showAbout()
    {
        if (page.aboutCard !== null && page.aboutCard !== undefined) {
            // ScrollablePage content is a flickable: center the About card.
            var y = page.aboutCard.y
            if (page.flickable !== undefined && page.flickable !== null) {
                page.flickable.contentY = Math.max(0, y - Kirigami.Units.largeSpacing)
            }
        }
    }

    // --- card surface (theme tokens with Kirigami fallbacks) ---------------
    // ThemeEngine gains cardBackground/cardBorder/cardRadius/cardPadding with
    // the Fluent pass; until then (or for themes without them) fall back to
    // Kirigami palette values so this page never renders unstyled.
    function cardColor()
    {
        try {
            var v = ThemeEngine["cardBackground"]
            if (v !== undefined && String(v).length > 0) {
                return v
            }
        } catch (e) {
        }
        return Kirigami.Theme.alternateBackgroundColor
    }

    function cardBorderColor()
    {
        try {
            var v = ThemeEngine["cardBorder"]
            if (v !== undefined && String(v).length > 0) {
                return v
            }
        } catch (e) {
        }
        return ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)
    }

    function cardRadius()
    {
        try {
            var v = ThemeEngine["cardRadius"]
            if (v !== undefined && v > 0) {
                return v
            }
        } catch (e) {
        }
        return Kirigami.Units.cornerRadius + 6
    }

    function cardPad()
    {
        try {
            var v = ThemeEngine["cardPadding"]
            if (v !== undefined && v > 0) {
                return v
            }
        } catch (e) {
        }
        return Kirigami.Units.largeSpacing
    }

    Component.onCompleted: {
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

    ColumnLayout {
        width: Math.min(parent.width, Kirigami.Units.gridUnit * 34)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Kirigami.Units.largeSpacing

        // ---------------- search ---------------- //
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.SearchField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: qsTr("Search settings")
                onTextChanged: page.filter = text.trim()
            }

            Controls.ToolButton {
                visible: page.filter.length > 0
                icon.name: "edit-clear"
                text: qsTr("Clear search")
                display: Controls.AbstractButton.IconOnly
                onClicked: searchField.text = ""

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Clear search")
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.filter.length > 0 && !identityCard.visible && !connectionCard.visible
                     && !appearanceCard.visible && !notifyCard.visible && !aboutCardItem.visible
            type: Kirigami.MessageType.Information
            text: qsTr("No settings match “%1”.").arg(page.filter)
        }

        // ---------------- Identity ---------------- //
        Rectangle {
            id: identityCard
            Layout.fillWidth: true
            visible: page.sectionVisible(["identity", "nickname", "nickserv", "account",
                                          "password", "sasl", "mechanism", "plain", "external", "auto"])
            implicitHeight: identityLayout.implicitHeight + page.cardPad() * 2
            radius: page.cardRadius()
            color: page.cardColor()
            border.width: 1
            border.color: page.cardBorderColor()

            ColumnLayout {
                id: identityLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: page.cardPad()
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("Identity")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true

                    Controls.TextField {
                        id: nickField
                        Kirigami.FormData.label: qsTr("Nickname:")
                        visible: page.rowVisible(qsTr("Nickname"))
                        placeholderText: qsTr("yournick")
                        onEditingFinished: page.persist()
                    }

                    Controls.TextField {
                        id: nickservNickField
                        Kirigami.FormData.label: qsTr("NickServ account:")
                        visible: page.rowVisible(qsTr("NickServ account"))
                        placeholderText: qsTr("Registered account (not your current nick)")
                        onEditingFinished: page.persist()
                    }

                    RowLayout {
                        Kirigami.FormData.label: qsTr("NickServ password:")
                        visible: page.rowVisible(qsTr("NickServ password"))

                        Controls.TextField {
                            id: nickservPassField
                            Layout.fillWidth: true
                            echoMode: showNickservPass.checked ? TextInput.Normal : TextInput.Password
                            placeholderText: qsTr("Stored in KWallet, never in kirc.conf")
                            onEditingFinished: page.persist()
                        }

                        Controls.ToolButton {
                            id: showNickservPass
                            checkable: true
                            icon.name: checked ? "password-show-off" : "password-show-on"
                            text: qsTr("Show")

                            Controls.ToolTip.visible: hovered
                            Controls.ToolTip.text: checked ? qsTr("Hide password") : qsTr("Show password")
                        }
                    }

                    Controls.Label {
                        visible: page.rowVisible(qsTr("NickServ password"))
                        Layout.fillWidth: true
                        text: qsTr("Stored in KWallet, never in kirc.conf.")
                        color: Kirigami.Theme.disabledTextColor
                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        wrapMode: Text.WordWrap
                    }

                    Controls.TextField {
                        id: saslUserField
                        Kirigami.FormData.label: qsTr("SASL user:")
                        visible: page.rowVisible(qsTr("SASL user"))
                        placeholderText: qsTr("SASL account name")
                        onEditingFinished: {
                            var win = applicationWindow()
                            if (win && win.appConfig) {
                                win.appConfig.saslUser = text
                                win.appConfig.save()
                            }
                        }
                    }

                    Controls.ComboBox {
                        id: saslMechBox
                        Kirigami.FormData.label: qsTr("SASL mechanism:")
                        visible: page.rowVisible(qsTr("SASL mechanism"))
                        model: [qsTr("Auto"), qsTr("PLAIN"), qsTr("EXTERNAL")]
                        onActivated: {
                            page.persist()
                            var win = applicationWindow()
                            if (win && win.saslMechanism !== undefined) {
                                win.saslMechanism = page.saslMechanismId(currentIndex)
                            }
                        }

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Auto negotiates SCRAM-SHA-256 when advertised, else PLAIN")
                    }
                }
            }
        }

        // ---------------- Connection ---------------- //
        Rectangle {
            id: connectionCard
            Layout.fillWidth: true
            visible: page.sectionVisible(["connection", "autojoin", "channel", "reconnect",
                                          "retry", "authentication", "identify"])
            implicitHeight: connectionLayout.implicitHeight + page.cardPad() * 2
            radius: page.cardRadius()
            color: page.cardColor()
            border.width: 1
            border.color: page.cardBorderColor()

            ColumnLayout {
                id: connectionLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: page.cardPad()
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("Connection")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true

                    Controls.Switch {
                        id: identifySwitch
                        Kirigami.FormData.label: qsTr("Identify:")
                        visible: page.rowVisible(qsTr("Identify"))
                        text: qsTr("Identify on connect, then autojoin")
                        onToggled: page.persist()

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Send NickServ IDENTIFY before joining channels")
                    }

                    // Autojoin as an add/remove list, persisted back to the
                    // comma-separated appConfig.autojoin string.
                    ColumnLayout {
                        Kirigami.FormData.label: qsTr("Autojoin:")
                        visible: page.rowVisible(qsTr("Autojoin"))
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: page.autojoinModel
                            delegate: RowLayout {
                                required property string modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Kirigami.Icon {
                                    source: "im-chat"
                                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    text: modelData
                                    elide: Text.ElideRight
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Controls.ToolButton {
                                    icon.name: "list-remove"
                                    text: qsTr("Remove %1").arg(modelData)
                                    display: Controls.AbstractButton.IconOnly
                                    Layout.alignment: Qt.AlignVCenter
                                    onClicked: {
                                        var out = page.autojoinModel.slice()
                                        out.splice(index, 1)
                                        page.autojoinModel = out
                                        page.persist()
                                    }

                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.text: qsTr("Remove %1").arg(modelData)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Controls.TextField {
                                id: autojoinAddField
                                Layout.fillWidth: true
                                placeholderText: qsTr("#channel")
                                onAccepted: autojoinAddButton.clicked()
                            }

                            Controls.ToolButton {
                                id: autojoinAddButton
                                icon.name: "list-add"
                                text: qsTr("Add channel")
                                display: Controls.AbstractButton.IconOnly
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

                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: qsTr("Add channel to autojoin")
                            }
                        }

                        Controls.Label {
                            visible: page.autojoinModel.length === 0
                            text: qsTr("No channels yet — joins on connect.")
                            color: Kirigami.Theme.disabledTextColor
                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                        }
                    }

                    Controls.Switch {
                        id: reconnectSwitch
                        Kirigami.FormData.label: qsTr("Reconnect:")
                        visible: page.rowVisible(qsTr("Reconnect"))
                        text: qsTr("Reconnect automatically if dropped")
                        checked: true
                        onToggled: page.persist()
                    }

                    Controls.TextField {
                        id: retryField
                        Kirigami.FormData.label: qsTr("Retry limit:")
                        visible: page.rowVisible(qsTr("Retry limit")) && page.hasPref("reconnectLimit")
                        placeholderText: qsTr("10 (0 = unlimited)")
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 0; top: 999 }
                        onEditingFinished: page.persist()

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Max automatic reconnect attempts (0 = unlimited)")
                    }

                    Controls.Switch {
                        id: authRetrySwitch
                        Kirigami.FormData.label: qsTr("Auth failures:")
                        visible: page.rowVisible(qsTr("Auth failures")) && page.hasPref("reconnectLimit")
                        text: qsTr("Reconnect after authentication failure")
                        onToggled: page.persist()

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Off by default, so a bad password cannot retry in a loop")
                    }
                }
            }
        }

        // ---------------- Appearance ---------------- //
        Rectangle {
            id: appearanceCard
            Layout.fillWidth: true
            visible: page.sectionVisible(["appearance", "theme", "density", "bubble",
                                          "compact", "font", "timestamp", "fluent",
                                          "light", "breeze", "classic", "oxygen", "neon"])
            implicitHeight: appearanceLayout.implicitHeight + page.cardPad() * 2
            radius: page.cardRadius()
            color: page.cardColor()
            border.width: 1
            border.color: page.cardBorderColor()

            ColumnLayout {
                id: appearanceLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: page.cardPad()
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("Appearance")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                }

                // ---- theme picker ------------------------------------------
                // Six friendly options (C++ may append more), each with a
                // three-dot preview of the theme's accent / surface / bubble
                // colours and a radio marker on the active one.  Picking an
                // option applies it immediately — ThemeEngine is a singleton,
                // so every binding in the window repaints — and persists it.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: page.rowVisible(qsTr("Theme"))
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: qsTr("Theme")
                        color: Kirigami.Theme.textColor
                        opacity: 0.75
                        font.bold: true
                        font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                    }

                    GridLayout {
                        id: themeGrid
                        Layout.fillWidth: true
                        // Two columns while the card is wide enough for legible
                        // names; one otherwise.
                        columns: themeGrid.width >= Kirigami.Units.gridUnit * 24 ? 2 : 1
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: ThemeEngine.availableThemeIds

                            delegate: Controls.RadioButton {
                                id: themeOption

                                required property string modelData
                                readonly property bool active: ThemeEngine.themeId === ThemeEngine.canonicalId(themeOption.modelData)
                                readonly property var preview: ThemeEngine.themePreview(
                                    themeOption.modelData,
                                    Kirigami.Theme.highlightColor,
                                    Kirigami.Theme.alternateBackgroundColor,
                                    Kirigami.Theme.disabledTextColor)

                                Layout.fillWidth: true
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 11
                                Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 2.4)
                                // Bound to the engine so the marker follows a
                                // theme change from anywhere (settings, toolbar
                                // menu, config restore).  RadioButton's own
                                // auto-exclusive group keeps one selection.
                                checked: themeOption.active
                                spacing: Kirigami.Units.smallSpacing
                                onClicked: page.selectTheme(themeOption.modelData)

                                Accessible.name: ThemeEngine.themeDisplayName(themeOption.modelData)
                                Accessible.description: themeOption.preview.mode === "dense"
                                    ? qsTr("Compact list layout") : qsTr("Bubble chat layout")

                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: qsTr("Apply the %1 theme — %2")
                                    .arg(ThemeEngine.themeDisplayName(themeOption.modelData))
                                    .arg(themeOption.preview.mode === "dense"
                                         ? qsTr("compact one-line list") : qsTr("bubble chat"))

                                background: Rectangle {
                                    radius: page.cardRadius()
                                    color: themeOption.active
                                        ? ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.10)
                                        : (themeOption.hovered
                                           ? ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.05)
                                           : page.cardColor())
                                    border.width: themeOption.active ? 2 : 1
                                    border.color: themeOption.active
                                        ? Kirigami.Theme.highlightColor
                                        : page.cardBorderColor()
                                    Behavior on color {
                                        ColorAnimation { duration: ThemeEngine.motionDuration }
                                    }
                                }

                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing

                                    // Accent / surface / bubble preview dots.
                                    // Plain items on purpose: a nested Repeater
                                    // here rebuilds its delegates while the
                                    // platform palette updates during the page
                                    // transition, which crashed Qt 6.11 (SIGSEGV
                                    // in QQuickItem layout re-entrancy).
                                    Row {
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: Math.max(1, Math.round(Kirigami.Units.smallSpacing / 2))

                                        ThemeSwatch {
                                            color: themeOption.preview.accent
                                        }
                                        ThemeSwatch {
                                            color: themeOption.preview.surface
                                        }
                                        ThemeSwatch {
                                            color: themeOption.preview.bubble
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0

                                        Controls.Label {
                                            Layout.fillWidth: true
                                            text: ThemeEngine.themeDisplayName(themeOption.modelData)
                                            font.bold: themeOption.active
                                            elide: Text.ElideRight
                                        }

                                        Controls.Label {
                                            Layout.fillWidth: true
                                            text: themeOption.preview.mode === "dense"
                                                ? qsTr("Compact one-line list") : qsTr("Bubble layout")
                                            color: Kirigami.Theme.disabledTextColor
                                            font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Kirigami.Icon {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: themeOption.active
                                        source: "checkmark"
                                        color: Kirigami.Theme.highlightColor
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                    }
                                }
                            }
                        }
                    }
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true

                    RowLayout {
                        Kirigami.FormData.label: qsTr("Density:")
                        visible: page.rowVisible(qsTr("Density"))
                        spacing: Kirigami.Units.smallSpacing

                        // Density is the theme's layout mode.  The radios track
                        // the active theme (a lighter theme is bubble, a
                        // classic/oxygen one is compact) and, when used, pick
                        // the canonical theme of that mode.
                        Controls.RadioButton {
                            id: densityBubbles
                            text: qsTr("Bubbles")
                            checked: ThemeEngine.mode !== "dense"
                            onClicked: page.selectTheme("breeze")

                            Controls.ToolTip.visible: hovered
                            Controls.ToolTip.text: qsTr("Bubble chat layout (switches to the Breeze theme)")
                        }

                        Controls.RadioButton {
                            id: densityCompact
                            text: qsTr("Compact")
                            checked: ThemeEngine.mode === "dense"
                            onClicked: page.selectTheme("breeze-classic")

                            Controls.ToolTip.visible: hovered
                            Controls.ToolTip.text: qsTr("Classic one-line-per-message layout (switches to the Breeze Classic theme)")
                        }
                    }

                    ColumnLayout {
                        Kirigami.FormData.label: qsTr("Font size:")
                        visible: page.rowVisible(qsTr("Font size"))
                        Layout.fillWidth: true
                        spacing: 0

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
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            text: qsTr("Aa — the quick brown fox")
                            font.pointSize: ThemeEngine.resolvePointSize(ThemeEngine.messageSize,
                                Kirigami.Theme.defaultFont.pointSize)
                            color: Kirigami.Theme.disabledTextColor
                        }
                    }

                    Controls.Switch {
                        id: timestampsSwitch
                        Kirigami.FormData.label: qsTr("Timestamps:")
                        visible: page.rowVisible(qsTr("Timestamps")) && page.hasPref("showTimestamps")
                        text: qsTr("Show message timestamps")
                        checked: true
                        onToggled: page.persist()
                    }
                }
            }
        }

        // ---------------- Notifications ---------------- //
        Rectangle {
            id: notifyCard
            Layout.fillWidth: true
            visible: page.sectionVisible(["notification", "highlight", "direct message",
                                          "tray", "minimize"])
            implicitHeight: notifyLayout.implicitHeight + page.cardPad() * 2
            radius: page.cardRadius()
            color: page.cardColor()
            border.width: 1
            border.color: page.cardBorderColor()

            ColumnLayout {
                id: notifyLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: page.cardPad()
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("Notifications")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true

                    Controls.Switch {
                        id: highlightSwitch
                        Kirigami.FormData.label: qsTr("Highlights:")
                        visible: page.rowVisible(qsTr("Highlights")) && page.hasPref("notifyHighlights")
                        text: qsTr("Notify on highlight")
                        checked: true
                        onToggled: page.persist()
                    }

                    Controls.Switch {
                        id: dmSwitch
                        Kirigami.FormData.label: qsTr("Direct messages:")
                        visible: page.rowVisible(qsTr("Direct messages")) && page.hasPref("notifyHighlights")
                        text: qsTr("Notify on direct message")
                        checked: true
                        onToggled: page.persist()
                    }

                    Controls.Switch {
                        id: traySwitch
                        Kirigami.FormData.label: qsTr("System tray:")
                        visible: page.rowVisible(qsTr("System tray"))
                        text: qsTr("Minimize to tray on close")
                        onToggled: page.persist()
                    }
                }
            }
        }

        // ---------------- About ---------------- //
        Rectangle {
            id: aboutCardItem
            Layout.fillWidth: true
            visible: page.sectionVisible(["about", "version", "kirc", "license", "kde"])
            implicitHeight: aboutLayout.implicitHeight + page.cardPad() * 2
            radius: page.cardRadius()
            color: page.cardColor()
            border.width: 1
            border.color: page.cardBorderColor()

            Component.onCompleted: page.aboutCard = aboutCardItem

            ColumnLayout {
                id: aboutLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: page.cardPad()
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: qsTr("About")
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 2.2)
                        implicitHeight: implicitWidth
                        radius: width * 0.3
                        color: Kirigami.Theme.highlightColor

                        Controls.Label {
                            anchors.centerIn: parent
                            text: "#"
                            color: Kirigami.Theme.highlightedTextColor
                            font.bold: true
                            font.pointSize: Math.round(Kirigami.Theme.defaultFont.pointSize * 1.4)
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Controls.Label {
                            text: qsTr("kIRC")
                            font.bold: true
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                        }

                        Controls.Label {
                            text: qsTr("A modern IRC client for KDE")
                            color: Kirigami.Theme.disabledTextColor
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    text: qsTr("Passwords are never written to kirc.conf: the NickServ password lives in KWallet, the SASL password lives only in memory for this session.")
                    color: Kirigami.Theme.disabledTextColor
                    font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                    wrapMode: Text.WordWrap
                }
            }
        }

        Item {
            Layout.preferredHeight: Kirigami.Units.largeSpacing
        }
    }
}
